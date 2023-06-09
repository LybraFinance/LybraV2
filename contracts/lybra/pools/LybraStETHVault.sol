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
    uint256 public lidoRebaseTime = 12 hours;

    constructor(
        address _config
    ) LybraEUSDVaultBase(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, _config) {}

    /**
     * @notice Sets the rebase time for Lido based on the actual situation.
     * This function can only be called by an address with the ADMIN role.
     */
    function setLidoRebaseTime(uint256 _time) external {
        require(configurator.hasRole(keccak256("ADMIN"), msg.sender));
        lidoRebaseTime = _time;
    }

    /**
     * @notice Allows users to deposit ETH to mint eUSD.
     * ETH is directly deposited into Lido and converted to stETH.
     * @param mintAmount The amount of eUSD to mint.
     * Requirements:
     * The deposited amount of ETH must be greater than or equal to 1 ETH.
     */
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
     * Emits a `LSDValueCaptured` event.
     *
     * *Requirements:
     * - stETH balance in the contract cannot be less than totalDepositedAsset after exchange.
     * @dev Income is used to cover accumulated Service Fee first.
     */
    function excessIncomeDistribution(uint256 stETHAmount) external override {
        require(
            stETHAmount <=
                collateralAsset.balanceOf(address(this)) -
                    totalDepositedAsset &&
                stETHAmount > 0,
            "Only LSD excess income can be exchanged"
        );
        uint256 payAmount = (((stETHAmount * _etherPrice()) / 1e18) *
            getDutchAuctionDiscountPrice()) / 10000;

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
                sharesAmount = (payAmount - income);
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
        collateralAsset.transfer(msg.sender, stETHAmount);
        emit LSDValueCaptured(
            stETHAmount,
            payAmount,
            getDutchAuctionDiscountPrice(),
            block.timestamp
        );
    }

    /**
     * @notice Reduces the discount for the issuance of additional tokens based on the rebase time using the Dutch auction method.
     * The specific rule is that the discount rate increases by 1% every 30 minutes after the rebase occurs.
     */
    function getDutchAuctionDiscountPrice() public view returns (uint256) {
        uint256 time = (block.timestamp - lidoRebaseTime) % 1 days;
        if (time < 30 minutes) return 10000;
        return 10000 - (time / 30 minutes - 1) * 100;
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
