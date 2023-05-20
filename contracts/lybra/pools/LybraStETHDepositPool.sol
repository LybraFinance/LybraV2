// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "../interfaces/IEUSD.sol";
import "./base/LybraRebaseAssetPoolBase.sol";

interface Ilido {
    function submit(address _referral) external payable returns (uint256 StETH);

    function withdraw(address _to) external returns (uint256 ETH);

    function balanceOf(address _account) external view returns (uint256);

    function transfer(
        address _recipient,
        uint256 _amount
    ) external returns (bool);

    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    ) external returns (bool);
}

contract LybraStETHDepositPool is LybraRebaseAssetPoolBase {
    Ilido public lido = Ilido(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    // Currently, the official rebase time for Lido is between 12PM to 13PM UTC.
    uint256 public lockdownPeriod = 12 hours;
    mapping(address => uint256) depositedTime;

    constructor(address _eusd, address _config) LybraRebaseAssetPoolBase(_eusd, _config) {
    }

    function depositEtherToMint(
        uint256 mintAmount
    ) external payable override {
        require(msg.value >= 1 ether, "Deposit should not be less than 1 ETH.");
        uint256 etherPrice = _etherPrice();
        require(msg.value * etherPrice >= mintAmount * 1e18, "");

        //convert to steth
        uint256 sharesAmount = lido.submit{value: msg.value}(owner());
        require(sharesAmount > 0, "ZERO_DEPOSIT");

        totalDepositedAsset += msg.value;
        depositedAsset[msg.sender] += msg.value;
        depositedTime[msg.sender] = block.timestamp;

        if (mintAmount > 0) {
            _mintEUSD(msg.sender, msg.sender, mintAmount, etherPrice);
        }

        emit DepositEther(msg.sender, msg.sender, msg.value, block.timestamp);
    }

    /**
     * @dev Record the deposited stETH in the ratio of 1:1.
     */
    function depositAssetToMint(
        uint256 assetAmount,
        uint256 mintAmount
    ) external override {
        require(
            assetAmount >= 1 ether,
            "Deposit should not be less than 1 stETH."
        );

        bool success = lido.transferFrom(
            msg.sender,
            address(this),
            assetAmount
        );
        require(success, "");

        totalDepositedAsset += assetAmount;
        depositedAsset[msg.sender] += assetAmount;
        depositedTime[msg.sender] = block.timestamp;

        if (mintAmount > 0) {
            uint256 assetPrice = getAssetPrice();
            _mintEUSD(msg.sender, msg.sender, mintAmount, assetPrice);
        }
        emit DepositAsset(
            msg.sender,
            address(lido),
            msg.sender,
            assetAmount,
            block.timestamp
        );
    }

    /**
     * @notice Withdraw collateral assets to an address
     * Emits a `WithdrawEther` event.
     *
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `amount` Must be higher than 0.
     *
     * @dev Withdraw stETH. Check user’s collateral rate after withdrawal, should be higher than `safeCollateralRate`
     */
    function withdraw(
        address onBehalfOf,
        uint256 assetAmount
    ) external override {
        require(onBehalfOf != address(0), "WITHDRAW_TO_THE_ZERO_ADDRESS");
        require(assetAmount > 0, "ZERO_WITHDRAW");
        require(
            depositedAsset[msg.sender] >= assetAmount,
            "Insufficient Balance"
        );
        totalDepositedAsset -= assetAmount;
        depositedAsset[msg.sender] -= assetAmount;

        uint256 withdrawal = checkWithdrawal(msg.sender, assetAmount);

        lido.transfer(onBehalfOf, withdrawal);
        if (borrowed[msg.sender] > 0) {
            uint256 etherPrice = _etherPrice();
            _checkHealth(msg.sender, etherPrice);
        }
        emit WithdrawAsset(
            msg.sender,
            address(lido),
            onBehalfOf,
            assetAmount,
            block.timestamp
        );
    }

    function checkWithdrawal(
        address user,
        uint256 amount
    ) internal view returns (uint256 withdrawal) {
        withdrawal = block.timestamp - 3 days >= depositedTime[user]
            ? amount
            : (amount * 999) / 1000;
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

    /**
     * @notice When overallCollateralRate is above 150%, Keeper liquidates borrowers whose collateral rate is below badCollateralRate, using EUSD provided by Liquidation Provider.
     *
     * Requirements:
     * - onBehalfOf Collateral Rate should be below badCollateralRate
     * - etherAmount should be less than 50% of collateral
     * - provider should authorize Lybra to utilize EUSD
     * @dev After liquidation, borrower's debt is reduced by etherAmount * etherPrice, collateral is reduced by the etherAmount corresponding to 110% of the value. Keeper gets keeperRate / 110 of Liquidation Reward and Liquidator gets the remaining stETH.
     */
    function liquidation(
        address provider,
        address onBehalfOf,
        uint256 assetAmount
    ) external override {
        uint256 etherPrice = _etherPrice();
        uint256 onBehalfOfCollateralRate = (depositedAsset[onBehalfOf] *
            etherPrice *
            100) / borrowed[onBehalfOf];
        require(
            onBehalfOfCollateralRate < configurator.badCollateralRate(),
            "Borrowers collateral rate should below badCollateralRate"
        );

        require(
            assetAmount * 2 <= depositedAsset[onBehalfOf],
            "a max of 50% collateral can be liquidated"
        );
        uint256 eusdAmount = (assetAmount * etherPrice) / 1e18;
        require(
            EUSD.allowance(provider, address(this)) >= eusdAmount,
            "provider should authorize to provide liquidation EUSD"
        );

        _repay(provider, onBehalfOf, eusdAmount);
        uint256 reducedEther = (assetAmount * 11) / 10;
        totalDepositedAsset -= reducedEther;
        depositedAsset[onBehalfOf] -= reducedEther;
        uint256 reward2keeper;
        if (provider == msg.sender) {
            lido.transfer(msg.sender, reducedEther);
        } else {
            reward2keeper = (reducedEther * configurator.poolKeeperRate(address(this))) / 110;
            lido.transfer(provider, reducedEther - reward2keeper);
            lido.transfer(msg.sender, reward2keeper);
        }
        emit LiquidationRecord(
            provider,
            msg.sender,
            onBehalfOf,
            eusdAmount,
            reducedEther,
            reward2keeper,
            false,
            block.timestamp
        );
    }

    /**
     * @notice When overallCollateralRate is below badCollateralRate, borrowers with collateralRate below 125% could be fully liquidated.
     * Emits a `LiquidationRecord` event.
     *
     * Requirements:
     * - Current overallCollateralRate should be below badCollateralRate
     * - `onBehalfOf`collateralRate should be below 125%
     * @dev After Liquidation, borrower's debt is reduced by etherAmount * etherPrice, deposit is reduced by etherAmount * borrower's collateralRate. Keeper gets a liquidation reward of `keeperRate / borrower's collateralRate
     */
    function superLiquidation(
        address provider,
        address onBehalfOf,
        uint256 assetAmount
    ) external override {
        uint256 etherPrice = _etherPrice();
        require(
            (totalDepositedAsset * etherPrice * 100) /
                poolTotalEUSDCirculation <
                configurator.badCollateralRate(),
            "overallCollateralRate should below 150%"
        );
        uint256 onBehalfOfCollateralRate = (depositedAsset[onBehalfOf] *
            etherPrice *
            100) / borrowed[onBehalfOf];
        require(
            onBehalfOfCollateralRate < 125 * 1e18,
            "borrowers collateralRate should below 125%"
        );
        require(
            assetAmount <= depositedAsset[onBehalfOf],
            "total of collateral can be liquidated at most"
        );
        uint256 eusdAmount = (assetAmount * etherPrice) / 1e18;
        if (onBehalfOfCollateralRate >= 1e20) {
            eusdAmount = (eusdAmount * 1e20) / onBehalfOfCollateralRate;
        }
        require(
            EUSD.allowance(provider, address(this)) >= eusdAmount,
            "provider should authorize to provide liquidation EUSD"
        );

        _repay(provider, onBehalfOf, eusdAmount);

        totalDepositedAsset -= assetAmount;
        depositedAsset[onBehalfOf] -= assetAmount;
        uint256 reward2keeper;
        if (
            msg.sender != provider &&
            onBehalfOfCollateralRate >= 1e20 + configurator.poolKeeperRate(address(this)) * 1e18
        ) {
            reward2keeper =
                ((assetAmount * configurator.poolKeeperRate(address(this))) * 1e18) /
                onBehalfOfCollateralRate;
            lido.transfer(msg.sender, reward2keeper);
        }
        lido.transfer(provider, assetAmount - reward2keeper);

        emit LiquidationRecord(
            provider,
            msg.sender,
            onBehalfOf,
            eusdAmount,
            assetAmount,
            reward2keeper,
            true,
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
                lido.balanceOf(address(this)) - totalDepositedAsset &&
                payoutEther > 0,
            "Only LSD excess income can be exchanged"
        );

        uint256 income = feeStored + _newFee();

        if (payAmount > income) {
            EUSD.transferFrom(msg.sender, address(configurator), income);

            try configurator.distributeDividends() {} catch {}

            uint256 sharesAmount = EUSD.getSharesByMintedEUSD(
                payAmount - income
            );
            if (sharesAmount == 0) {
                //EUSD totalSupply is 0: assume that shares correspond to EUSD 1-to-1
                sharesAmount = payAmount - income;
            }
            //Income is distributed to LBR staker.
            EUSD.burnShares(msg.sender, payAmount - income);
            feeStored = 0;
            emit FeeDistribution(
                address(configurator),
                income,
                block.timestamp
            );
        } else {
            EUSD.transferFrom(msg.sender, address(configurator), payAmount);
            try configurator.distributeDividends() {} catch {}
            feeStored = income - payAmount;
            emit FeeDistribution(
                address(configurator),
                payAmount,
                block.timestamp
            );
        }

        lastReportTime = block.timestamp;
        lido.transfer(msg.sender, payoutEther);

        emit LSDistribution(payoutEther, payAmount, block.timestamp);
    }

    /**
     * @notice Choose a Redemption Provider, Rigid Redeem `eusdAmount` of EUSD and get 1:1 value of stETH
     * Emits a `RigidRedemption` event.
     *
     * *Requirements:
     * - `provider` must be a Redemption Provider
     * - `provider`debt must equal to or above`eusdAmount`
     * @dev Service Fee for rigidRedemption `redemptionFee` is set to 0.5% by default, can be revised by DAO.
     */
    function rigidRedemption(
        address provider,
        uint256 eusdAmount
    ) external override {
        require(
            configurator.isRedemptionProvider(provider),
            "provider is not a RedemptionProvider"
        );
        require(
            borrowed[provider] >= eusdAmount,
            "eusdAmount cannot surpass providers debt"
        );
        uint256 etherPrice = _etherPrice();
        uint256 providerCollateralRate = (depositedAsset[provider] *
            etherPrice *
            100) / borrowed[provider];
        require(
            providerCollateralRate >= 100 * 1e18,
            "provider's collateral rate should more than 100%"
        );
        _repay(msg.sender, provider, eusdAmount);
        uint256 etherAmount = (((eusdAmount * 1e18) / etherPrice) *
            (10000 - configurator.redemptionFee())) / 10000;
        depositedAsset[provider] -= etherAmount;
        totalDepositedAsset -= etherAmount;
        lido.transfer(msg.sender, etherAmount);
        emit RigidRedemption(
            msg.sender,
            provider,
            eusdAmount,
            etherAmount,
            block.timestamp
        );
    }

    function _mintEUSD(
        address _provider,
        address _onBehalfOf,
        uint256 _mintAmount,
        uint256 _assetPrice
    ) internal override {
        checkPausedByLido();
        require(poolTotalEUSDCirculation + _mintAmount <= configurator.mintPoolMaxSupply(address(this)), "");
        try configurator.refreshMintReward(_provider) {} catch {}
        borrowed[_provider] += _mintAmount;

        EUSD.mint(_onBehalfOf, _mintAmount);
        _saveReport();
        poolTotalEUSDCirculation += _mintAmount;
        _checkHealth(_provider, _assetPrice);
        emit Mint(msg.sender, _onBehalfOf, _mintAmount, block.timestamp);
    }

    function _repay(
        address _provider,
        address _onBehalfOf,
        uint256 _amount
    ) internal override {
        uint256 amount = borrowed[_onBehalfOf] >= _amount
            ? _amount
            : borrowed[_onBehalfOf];

        EUSD.burn(_provider, amount);
        try configurator.refreshMintReward(_onBehalfOf) {} catch {}

        borrowed[_onBehalfOf] -= amount;
        _saveReport();
        poolTotalEUSDCirculation -= amount;
        emit Burn(_provider, _onBehalfOf, amount, block.timestamp);
    }

    /**
     * @dev Get USD value of current collateral asset and minted EUSD through price oracle / Collateral asset USD value must higher than safe Collateral Rate.
     */
    function _checkHealth(address _user, uint256 _assetPrice) internal view {
        if (
            ((depositedAsset[_user] * _assetPrice * 100) / borrowed[_user]) <
            configurator.getSafeCollateralRate(address(this))
        ) revert("collateralRate is Below safeCollateralRate");
    }

    function setLockdownPeriod(uint256 _time) external onlyOwner {
        lockdownPeriod = _time;
    }

    function getAssetPrice() public override returns (uint256) {
        return _etherPrice();
    }
}
