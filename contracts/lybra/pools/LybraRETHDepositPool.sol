// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "../interfaces/IEUSD.sol";
import "./base/LybraNonRebaseAssetPoolBase.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";


interface IRETH is IERC20 {
    function getEthValue(uint256 _rethAmount) external view returns (uint256);
}

interface IPriceFeed {
    function fetchPrice() external returns (uint256);
}

contract LybraRETHDepositPool is LybraNonRebaseAssetPoolBase {

    IRETH rETH = IRETH(0xae78736Cd615f374D3085123A210448E74Fc6393);
    constructor(address _eusd, address _config, uint256 _mintFee) LybraNonRebaseAssetPoolBase(_eusd, 0xae78736Cd615f374D3085123A210448E74Fc6393, _config) {
    }

    function depositAssetToMint(
        uint256 assetAmount,
        uint256 mintAmount
    ) external override{
        require(assetAmount >= 1 ether, "Deposit should not be less than 1 rETH.");
        uint256 preBalance = rETH.balanceOf(address(this));
        rETH.transferFrom(msg.sender, address(this), assetAmount);
        require(rETH.balanceOf(address(this)) >= preBalance + assetAmount, "");


        depositedAsset[msg.sender] += assetAmount;
        if (mintAmount > 0) {
            uint256 assetPrice = getAssetPrice();
            _mintEUSD(msg.sender, msg.sender, mintAmount, assetPrice);
        }
        emit DepositAsset(msg.sender, address(rETH), assetAmount, block.timestamp);
    }

    /**
     * @notice Withdraw collateral assets to an address
     * Emits a `WithdrawAsset` event.
     *
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `amount` Must be higher than 0.
     *
     * @dev Withdraw stETH. Check user’s collateral rate after withdrawal, should be higher than `configurator.getSafeCollateralRate(address(this))`
     */
    function withdraw(address onBehalfOf, uint256 amount) external override {
        require(onBehalfOf != address(0), "WTZ");
        require(amount > 0, "ZERO_WITHDRAW");
        require(depositedAsset[msg.sender] >= amount, "Withdraw amount exceeds deposited amount.");
        depositedAsset[msg.sender] -= amount;

        rETH.transfer(onBehalfOf, amount);
        if (borrowedShares[msg.sender] > 0) {
            _checkHealth(msg.sender, getAssetPrice());
        }
        emit WithdrawAsset(msg.sender, address(rETH), onBehalfOf, amount, block.timestamp);
    }

    /**
     * @notice When overallCollateralRate is above 150%, Keeper liquidates borrowers whose collateral rate is below badCollateralRate, using EUSD provided by Liquidation Provider.
     *
     * Requirements:
     * - onBehalfOf Collateral Rate should be below badCollateralRate
     * - assetAmount should be less than 50% of collateral
     * - provider should authorize Lybra to utilize EUSD
     * @dev After liquidation, borrower's debt is reduced by assetAmount * assetPrice, collateral is reduced by the assetAmount corresponding to 110% of the value. Keeper gets keeperRate / 110 of Liquidation Reward and Liquidator gets the remaining stETH.
     */
    function liquidation(
        address provider,
        address onBehalfOf,
        uint256 assetAmount
    ) external override {
        uint256 assetPrice = getAssetPrice();
        uint256 onBehalfOfCollateralRate = (depositedAsset[onBehalfOf] *
            assetPrice *
            100) / getBorrowedOf(onBehalfOf);
        require(
            onBehalfOfCollateralRate < configurator.badCollateralRate(),
            "Borrowers collateral rate should below badCollateralRate"
        );

        require(
            assetAmount * 2 <= depositedAsset[onBehalfOf],
            "a max of 50% collateral can be liquidated"
        );
        uint256 eusdAmount = (assetAmount * assetPrice) / 1e18;
        require(
            EUSD.allowance(provider, address(this)) >= eusdAmount,
            "provider should authorize to provide liquidation EUSD"
        );

        _repay(provider, onBehalfOf, eusdAmount);
        uint256 reducedAsset = (assetAmount * 11) / 10;
        depositedAsset[onBehalfOf] -= reducedAsset;
        uint256 reward2keeper;
        if (provider == msg.sender) {
            rETH.transfer(msg.sender, reducedAsset);
        } else {
            reward2keeper = (reducedAsset * configurator.poolKeeperRate(address(this))) / 110;
            rETH.transfer(provider, reducedAsset - reward2keeper);
            rETH.transfer(msg.sender, reward2keeper);
        }
        emit LiquidationRecord(
            provider,
            msg.sender,
            onBehalfOf,
            eusdAmount,
            reducedAsset,
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
     * @dev After Liquidation, borrower's debt is reduced by assetAmount * assetPrice, deposit is reduced by assetAmount * borrower's collateralRate. Keeper gets a liquidation reward of `keeperRate / borrower's collateralRate
     */
    function superLiquidation(
        address provider,
        address onBehalfOf,
        uint256 assetAmount
    ) external override {
        uint256 assetPrice = getAssetPrice();
        require(
            (totalDepositedAsset() * assetPrice * 100) / getPoolTotalEUSDCirculation() <
                configurator.badCollateralRate(),
            "overallCollateralRate should below 150%"
        );
        uint256 onBehalfOfCollateralRate = (depositedAsset[onBehalfOf] *
            assetPrice *
            100) / getBorrowedOf(onBehalfOf);
        require(
            onBehalfOfCollateralRate < 125 * 1e18,
            "borrowers collateralRate should below 125%"
        );
        require(
            assetAmount <= depositedAsset[onBehalfOf],
            "total of collateral can be liquidated at most"
        );
        uint256 eusdAmount = (assetAmount * assetPrice) / 1e18;
        if (onBehalfOfCollateralRate >= 1e20) {
            eusdAmount = (eusdAmount * 1e20) / onBehalfOfCollateralRate;
        }
        require(
            EUSD.allowance(provider, address(this)) >= eusdAmount,
            "provider should authorize to provide liquidation EUSD"
        );

        _repay(provider, onBehalfOf, eusdAmount);

        depositedAsset[onBehalfOf] -= assetAmount;
        uint256 reward2keeper;
        if (
            msg.sender != provider &&
            onBehalfOfCollateralRate >= 1e20 + configurator.poolKeeperRate(address(this)) * 1e18
        ) {
            reward2keeper =
                ((assetAmount * configurator.poolKeeperRate(address(this))) * 1e18) /
                onBehalfOfCollateralRate;
            rETH.transfer(msg.sender, reward2keeper);
        }
        rETH.transfer(provider, assetAmount - reward2keeper);

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
     * @notice Choose a Redemption Provider, Rigid Redeem `eusdAmount` of EUSD and get 1:1 value of stETH
     * Emits a `RigidRedemption` event.
     *
     * *Requirements:
     * - `provider` must be a Redemption Provider
     * - `provider`debt must equal to or above`eusdAmount`
     * @dev Service Fee for rigidRedemption `redemptionFee` is set to 0.5% by default, can be revised by DAO.
     */
    function rigidRedemption(address provider, uint256 eusdAmount) external override {
        require(
            configurator.isRedemptionProvider(provider),
            "provider is not a RedemptionProvider"
        );
        uint256 borrowedEUSD = EUSD.getMintedEUSDByShares(borrowedShares[provider]);
        require(
            borrowedEUSD >= eusdAmount,
            "eusdAmount cannot surpass providers debt"
        );
        uint256 assetPrice = getAssetPrice();
        uint256 providerCollateralRate = (depositedAsset[provider] *
            assetPrice *
            100) / borrowedEUSD;
        require(
            providerCollateralRate >= 100 * 1e18,
            "provider's collateral rate should more than 100%"
        );
        _repay(msg.sender, provider, eusdAmount);
        uint256 rETHAmount = (((eusdAmount * 1e18) / assetPrice) *
            (10000 - configurator.redemptionFee())) / 10000;
        depositedAsset[provider] -= rETHAmount;
        rETH.transfer(msg.sender, rETHAmount);
        emit RigidRedemption(
            msg.sender,
            provider,
            eusdAmount,
            rETHAmount,
            block.timestamp
        );
    }

    function _mintEUSD(
        address _provider,
        address _onBehalfOf,
        uint256 _mintAmount,
        uint256 _assetPrice
    ) internal override {
        require(getPoolTotalEUSDCirculation() + _mintAmount <= configurator.mintPoolMaxSupply(address(this)), "");
        _updateFee(_provider);

        try configurator.refreshMintReward(_provider) {} catch {}
        uint256 sharesAmount = EUSD.getSharesByMintedEUSD(
                _mintAmount
            );
        borrowedShares[_provider] += sharesAmount;

        EUSD.mint(_onBehalfOf, _mintAmount);
        poolTotalEUSDShares += sharesAmount;
        _checkHealth(_provider, _assetPrice);
        emit Mint(_provider, _onBehalfOf, _mintAmount, block.timestamp);
    }

    function _repay(
        address _provider,
        address _onBehalfOf,
        uint256 _amount
    ) internal override {
        uint256 totalFee = feeStored[_onBehalfOf] + _newFee(_onBehalfOf);
        try configurator.refreshMintReward(_onBehalfOf) {} catch {}
        uint256 borrowedEUSD = EUSD.getMintedEUSDByShares(getBorrowedOf(_onBehalfOf));

        uint256 amount = borrowedEUSD >= _amount ? _amount : borrowedEUSD;
        uint256 sharesAmount = EUSD.getSharesByMintedEUSD(amount);

        if(sharesAmount > totalFee) {
            borrowedShares[_onBehalfOf] -= (sharesAmount - totalFee);
            feeStored[_onBehalfOf] = 0;
            uint256 feeAmount = EUSD.getMintedEUSDByShares(totalFee);
            bool success = EUSD.transferFrom(_provider, address(configurator), feeAmount);
            require(success, "TF");
            EUSD.burn(_provider, amount - feeAmount);
        } else {
            feeStored[_onBehalfOf] = totalFee - sharesAmount;
            bool success = EUSD.transferFrom(_provider, address(configurator), EUSD.getMintedEUSDByShares(sharesAmount));
            require(success, "TF");
        }
        try configurator.distributeDividends() {} catch {}

        feeUpdatedAt[_onBehalfOf] = block.timestamp;
        poolTotalEUSDShares -= sharesAmount;
        emit Burn(_provider, _onBehalfOf, amount, block.timestamp);
    }

     /**
     * @dev Get USD value of current collateral asset and minted EUSD through price oracle / Collateral asset USD value must higher than safe Collateral Rate.
     */
    function _checkHealth(address user, uint256 price) internal view {
        if (
            ((depositedAsset[user] * price * 100) / EUSD.getMintedEUSDByShares(getBorrowedOf(user)) ) <
            configurator.getSafeCollateralRate(address(this))
        ) revert("collateralRate is Below safeCollateralRate");
    }

    function getAssetPrice() public override returns (uint256) {
        uint etherPrice = IPriceFeed(0x4c517D4e2C851CA76d7eC94B805269Df0f2201De).fetchPrice();
        return etherPrice * rETH.getEthValue(1e18) / 1e18;

    }

    function getAsset() external view override returns (address) {
        return address(rETH);
    }

}
