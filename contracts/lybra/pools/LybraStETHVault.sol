// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "../interfaces/IEUSD.sol";
import "./base/LybraEUSDVaultBase.sol";

interface IPriceFeed {
    function fetchPrice() external returns (uint256);
}

interface Ilido {
    function submit(address _referral) external payable returns (uint256 StETH);
}

contract LybraStETHDepositVault is LybraEUSDVaultBase {
    // Currently, the official rebase time for Lido is between 12PM to 13PM UTC.
    uint256 public lockdownPeriod = 12 hours;

    constructor(
        address _config
    ) LybraEUSDVaultBase(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, _config) {}

    function depositEtherToMint(uint256 mintAmount) external payable override {
        require(msg.value >= 1 ether, "DNL");

        //convert to steth
        uint256 sharesAmount = Ilido(address(collateralAsset)).submit{
            value: msg.value
        }(address(configurator));
        require(sharesAmount > 0, "ZERO_DEPOSIT");

        totalDepositedAsset += msg.value;
        depositedAsset[msg.sender] += msg.value;
        depositedTime[msg.sender] = block.timestamp;

        if (mintAmount > 0) {
            _mintEUSD(msg.sender, msg.sender, mintAmount, _etherPrice());
        }

        emit DepositEther(
            msg.sender,
            address(collateralAsset),
            msg.value,
            msg.value,
            block.timestamp
        );
    }

    /**
     * @notice When stETH balance increases through LSD or other reasons, the excess income is sold for EUSD, allocated to EUSD holders through rebase mechanism.
     * Emits a `LSDistribution` event.
     *
     * *Requirements:
     * - stETH balance in the contract cannot be less than totalDepositedAsset after exchange.
     * @dev Income is used to cover accumulated Service Fee first.
     */
    function excessIncomeDistribution(uint256 payAmount) external override {
        uint256 payoutEther = (payAmount * 1e18) / _etherPrice();
        require(
            payoutEther <=
                collateralAsset.balanceOf(address(this)) -
                    totalDepositedAsset &&
                payoutEther > 0,
            "Only LSD excess income can be exchanged"
        );

        uint256 income = feeStored + _newFee();
        if (payAmount > income) {
            bool success = EUSD.transferFrom(
                msg.sender,
                address(configurator),
                income
            );
            require(success, "TF");

            try configurator.distributeDividends() {} catch {}

            uint256 sharesAmount = EUSD.getSharesByMintedEUSD(
                payAmount - income
            );
            if (sharesAmount == 0) {
                //EUSD totalSupply is 0: assume that shares correspond to EUSD 1-to-1
                sharesAmount = payAmount - income;
            }
            //Income is distributed to LBR staker.
            EUSD.burnShares(msg.sender, sharesAmount);
            feeStored = 0;
            emit FeeDistribution(
                address(configurator),
                income,
                block.timestamp
            );
        } else {
            bool success = EUSD.transferFrom(
                msg.sender,
                address(configurator),
                payAmount
            );
            require(success, "TF");
            try configurator.distributeDividends() {} catch {}
            feeStored = income - payAmount;
            emit FeeDistribution(
                address(configurator),
                payAmount,
                block.timestamp
            );
        }

        lastReportTime = block.timestamp;
        collateralAsset.transfer(msg.sender, payoutEther);
        emit LSDistribution(payoutEther, payAmount, block.timestamp);
    }

    /**
     * @dev To limit the behavior of arbitrageurs who mint a large amount of eUSD after stETH rebase and before eUSD interest distribution to earn extra profit,
     * a 1-hour revert during stETH rebase is implemented to eliminate this issue.
     */
    function checkPausedByLido() internal view {
        require(
            (block.timestamp - lockdownPeriod) % 1 days > 1 hours,
            "Minting and repaying functions of eUSD are temporarily disabled during stETH rebasing periods."
        );
    }

    function _mintEUSD(
        address _provider,
        address _onBehalfOf,
        uint256 _mintAmount,
        uint256 _assetPrice
    ) internal override {
        checkPausedByLido();
        require(
            poolTotalEUSDCirculation + _mintAmount <=
                configurator.mintVaultMaxSupply(address(this)),
            "ESL"
        );
        try configurator.refreshMintReward(_provider) {} catch {}
        borrowed[_provider] += _mintAmount;

        EUSD.mint(_onBehalfOf, _mintAmount);
        _saveReport();
        poolTotalEUSDCirculation += _mintAmount;
        _checkHealth(_provider, _assetPrice);
        emit Mint(msg.sender, _onBehalfOf, _mintAmount, block.timestamp);
    }

    function setLockdownPeriod(uint256 _time) external {
        require(configurator.hasRole(keccak256("ADMIN"), msg.sender));
        lockdownPeriod = _time;
    }

    function getAssetPrice() public override returns (uint256) {
        return _etherPrice();
    }

    /**
     * @dev Return USD value of current ETH through Liquity PriceFeed Contract.
     * https://etherscan.io/address/0x4c517D4e2C851CA76d7eC94B805269Df0f2201De#code
     */
    function _etherPrice() internal returns (uint256) {
        return
            IPriceFeed(0x4c517D4e2C851CA76d7eC94B805269Df0f2201De).fetchPrice();
    }
}
