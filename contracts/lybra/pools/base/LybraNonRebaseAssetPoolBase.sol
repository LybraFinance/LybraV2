// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "../../interfaces/IEUSD.sol";
import "../../interfaces/Iconfigurator.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LybraNonRebaseAssetPoolBase {
    IEUSD public immutable EUSD;
    IERC20 public immutable collateralAsset;
    Iconfigurator public immutable configurator;
    //
    uint8 immutable borrowType = 1;
    uint256 public poolTotalEUSDShares;

    mapping(address => uint256) public depositedAsset;
    mapping(address => uint256) borrowedShares;
    mapping(address => uint256) feeStored;
    mapping(address => uint256) feeUpdatedAt;

    event DepositAsset(
        address indexed onBehalfOf,
        address asset,
        uint256 amount,
        uint256 timestamp
    );
    event WithdrawAsset(
        address sponsor,
        address indexed onBehalfOf,
        address asset,
        uint256 amount,
        uint256 timestamp
    );
    event Mint(
        address sponsor,
        address indexed onBehalfOf,
        uint256 amount,
        uint256 timestamp
    );
    event Burn(
        address sponsor,
        address indexed onBehalfOf,
        uint256 amount,
        uint256 timestamp
    );
    event LiquidationRecord(
        address provider,
        address keeper,
        address indexed onBehalfOf,
        uint256 eusdamount,
        uint256 LiquidateAssetAmount,
        uint256 keeperReward,
        bool superLiquidation,
        uint256 timestamp
    );
    event LSDistribution(
        uint256 stETHAdded,
        uint256 payoutEUSD,
        uint256 timestamp
    );
    event RigidRedemption(
        address indexed caller,
        address indexed provider,
        uint256 eusdAmount,
        uint256 assetAmount,
        uint256 timestamp
    );
    event FeeDistribution(
        address indexed feeAddress,
        uint256 feeAmount,
        uint256 timestamp
    );
    
    constructor(address _eusd, address _collateral, address _configurator) {
        EUSD = IEUSD(_eusd);
        collateralAsset = IERC20(_collateral);
        configurator = Iconfigurator(_configurator);
    }

    function totalDepositedAsset() public view returns(uint256) {
        return collateralAsset.balanceOf(address(this));
    }

    /**
     * @notice Deposit staked ETH, update the interest distribution, can mint EUSD directly
     * Emits a `DepositAsset` event.
     *
     * Requirements:
     * - `assetAmount` Must be higher than 0.
     * - `mintAmount` Send 0 if doesn't mint EUSD
     */
    function depositAssetToMint(
        uint256 assetAmount,
        uint256 mintAmount
    ) external virtual {}

    /**
     * @notice Withdraw collateral assets to an address
     * Emits a `WithdrawAsset` event.
     *
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `amount` Must be higher than 0.
     *
     * @dev Withdraw stETH. Check user’s collateral rate after withdrawal, should be higher than `safeCollateralRate`
     */
    function withdraw(address onBehalfOf, uint256 amount) external virtual {}

    /**
     * @notice The mint amount number of EUSD is minted to the address
     * Emits a `Mint` event.
     *
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `amount` Must be higher than 0. Individual mint amount shouldn't surpass 10% when the circulation reaches 10_000_000
     */
    function mint(address onBehalfOf, uint256 amount) public {
        require(onBehalfOf != address(0), "MINT_TO_THE_ZERO_ADDRESS");
        require(amount > 0, "ZERO_MINT");
        _mintEUSD(msg.sender, onBehalfOf, amount, getAssetPrice());
    }

    /**
     * @notice Burn the amount of EUSD and payback the amount of minted EUSD
     * Emits a `Burn` event.
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `amount` Must be higher than 0.
     * @dev Calling the internal`_repay`function.
     */
    function burn(address onBehalfOf, uint256 amount) external {
        require(onBehalfOf != address(0), "BURN_TO_THE_ZERO_ADDRESS");
        _repay(msg.sender, onBehalfOf, amount);
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
    ) external virtual {}

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
    ) external virtual {}

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
    ) external virtual {}

    /**
     * @dev Refresh LBR reward before adding providers debt. Refresh Lybra generated service fee before adding totalSupply. Check providers collateralRate cannot below `safeCollateralRate`after minting.
     */
    function _mintEUSD(
        address _provider,
        address _onBehalfOf,
        uint256 _mintAmount,
        uint256 _ethPrice
    ) internal virtual {}

    /**
     * @notice Burn _provideramount EUSD to payback minted EUSD for _onBehalfOf.
     *
     * @dev Refresh LBR reward before reducing providers debt. Refresh Lybra generated service fee before reducing totalEUSDCirculation.
     */
    function _repay(
        address _provider,
        address _onBehalfOf,
        uint256 _amount
    ) internal virtual {}

    function _updateFee(address user) internal {
        feeStored[user] += _newFee(user);
        feeUpdatedAt[user] = block.timestamp;
    }
    

    function _newFee(address user) internal view returns (uint256) {
        return
            (borrowedShares[user] *
                configurator.poolMintFeeApy(address(this)) *
                (block.timestamp - feeUpdatedAt[user])) /
            (86400 * 365) /
            10000;
    }


    /**
     * @dev Returns the current borrowing amount for the user, including borrowed shares and accumulated fees.
     * @param user The address of the user.
     * @return The total borrowing amount for the user.
     */
    function getBorrowedOf(address user) public view returns (uint256) {
        return borrowedShares[user] + feeStored[user] + _newFee(user);
    }

    function getBorrowType() external pure returns (uint8) {
        return borrowType;
    }

    function getPoolTotalEUSDCirculation() public view returns (uint256) {
        return EUSD.getMintedEUSDByShares(poolTotalEUSDShares);
    }

    function getAsset() external view virtual returns (address) {}

    function getAssetPrice() public virtual returns (uint256) {
    }
}
