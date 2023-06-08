// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "../../interfaces/IEUSD.sol";
import "../../interfaces/Iconfigurator.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface LbrStakingPool {
    function notifyRewardAmount(uint256 amount) external;
}

abstract contract LybraEUSDVaultBase {
    IEUSD public immutable EUSD;
    IERC20 public immutable collateralAsset;
    Iconfigurator public immutable configurator;
    uint256 public immutable badCollateralRatio = 150 * 1e18;

    uint256 public totalDepositedAsset;
    uint256 public lastReportTime;
    uint256 public poolTotalEUSDCirculation;

    mapping(address => uint256) public depositedAsset;
    mapping(address => uint256) borrowed;
    uint8 immutable vaultType = 0;
    uint256 public feeStored;
    mapping(address => uint256) depositedTime;

    event DepositEther(
        address indexed onBehalfOf,
        address asset,
        uint256 etherAmount,
        uint256 assetAmount,
        uint256 timestamp
    );

    event DepositAsset(
        address indexed onBehalfOf,
        address asset,
        uint256 amount,
        uint256 timestamp
    );

    event WithdrawAsset(
        address sponsor,
        address asset,
        address indexed onBehalfOf,
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
        uint256 liquidateEtherAmount,
        uint256 keeperReward,
        bool superLiquidation,
        uint256 timestamp
    );
    event LSDistribution(
        uint256 stETHAdded,
        uint256 payoutEUSD,
        uint256 timestamp
    );
    event RedemptionProvider(address user, bool status);
    event RigidRedemption(
        address indexed caller,
        address indexed provider,
        uint256 eusdAmount,
        uint256 collateralAmount,
        uint256 timestamp
    );
    event FeeDistribution(
        address indexed feeAddress,
        uint256 feeAmount,
        uint256 timestamp
    );

    constructor(address _collateralAsset, address _configurator) {
        collateralAsset = IERC20(_collateralAsset);
        configurator = Iconfigurator(_configurator);
        EUSD = IEUSD(configurator.getEUSDAddress());
    }

    /**
     * @notice Allowing direct deposits of ETH, the pool may convert it into the corresponding collateral during the implementation.
     * While depositing, it is possible to simultaneously mint eUSD for oneself.
     * Emits a `DepositEther` event.
     *
     * Requirements:
     * - `mintAmount` Send 0 if doesn't mint EUSD
     * - msg.value Must be higher than 0.
     */
    function depositEtherToMint(uint256 mintAmount) external payable virtual;

    /**
     * @notice Deposit collateral and allow minting eUSD for oneself.
     * Emits a `DepositAsset` event.
     *
     * Requirements:
     * - `assetAmount` Must be higher than 0.
     * - `mintAmount` Send 0 if doesn't mint EUSD
     */
    function depositAssetToMint(
        uint256 assetAmount,
        uint256 mintAmount
    ) external virtual {
        require(
            assetAmount >= 1 ether,
            "Deposit should not be less than 1 stETH."
        );

        bool success = collateralAsset.transferFrom(
            msg.sender,
            address(this),
            assetAmount
        );
        require(success, "TF");

        totalDepositedAsset += assetAmount;
        depositedAsset[msg.sender] += assetAmount;
        depositedTime[msg.sender] = block.timestamp;

        if (mintAmount > 0) {
            _mintEUSD(msg.sender, msg.sender, mintAmount, getAssetPrice());
        }
        emit DepositAsset(
            msg.sender,
            address(collateralAsset),
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
     * @dev Withdraw stETH. Check user’s collateral ratio after withdrawal, should be higher than `safeCollateralRatio`
     */
    function withdraw(address onBehalfOf, uint256 amount) external virtual {
        require(onBehalfOf != address(0), "TZA");
        require(amount > 0, "ZERO_WITHDRAW");
        require(
            depositedAsset[msg.sender] >= amount,
            "Withdraw amount exceeds deposited amount."
        );
        totalDepositedAsset -= amount;
        depositedAsset[msg.sender] -= amount;

        uint256 withdrawal = checkWithdrawal(msg.sender, amount);

        collateralAsset.transfer(onBehalfOf, withdrawal);
        if (borrowed[msg.sender] > 0) {
            _checkHealth(msg.sender, getAssetPrice());
        }
        emit WithdrawAsset(
            msg.sender,
            address(collateralAsset),
            onBehalfOf,
            withdrawal,
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
     * @notice The mint amount number of EUSD is minted to the address
     * Emits a `Mint` event.
     *
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `amount` Must be higher than 0. Individual mint amount shouldn't surpass 10% when the circulation reaches 10_000_000
     */
    function mint(address onBehalfOf, uint256 amount) external {
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
     * @notice When overallCollateralRatio is above 150%, Keeper liquidates borrowers whose collateral ratio is below badCollateralRatio, using EUSD provided by Liquidation Provider.
     *
     * Requirements:
     * - onBehalfOf Collateral Ratio should be below badCollateralRatio
     * - collateralAmount should be less than 50% of collateral
     * - provider should authorize Lybra to utilize EUSD
     * @dev After liquidation, borrower's debt is reduced by collateralAmount * etherPrice, collateral is reduced by the collateralAmount corresponding to 110% of the value. Keeper gets keeperRatio / 110 of Liquidation Reward and Liquidator gets the remaining stETH.
     */
    function liquidation(
        address provider,
        address onBehalfOf,
        uint256 assetAmount
    ) external virtual {
        uint256 assetPrice = getAssetPrice();
        uint256 onBehalfOfCollateralRatio = (depositedAsset[onBehalfOf] *
            assetPrice *
            100) / borrowed[onBehalfOf];
        require(
            onBehalfOfCollateralRatio < badCollateralRatio,
            "Borrowers collateral ratio should below badCollateralRatio"
        );

        require(
            assetAmount * 2 <= depositedAsset[onBehalfOf],
            "a max of 50% collateral can be liquidated"
        );
        require(
            EUSD.allowance(provider, address(this)) > 0,
            "provider should authorize to provide liquidation EUSD"
        );
        uint256 eusdAmount = (assetAmount * assetPrice) / 1e18;

        _repay(provider, onBehalfOf, eusdAmount);
        uint256 reducedAsset = (assetAmount * 11) / 10;
        totalDepositedAsset -= reducedAsset;
        depositedAsset[onBehalfOf] -= reducedAsset;
        uint256 reward2keeper;
        if (provider == msg.sender) {
            collateralAsset.transfer(msg.sender, reducedAsset);
        } else {
            reward2keeper =
                (reducedAsset * configurator.vaultKeeperRatio(address(this))) /
                110;
            collateralAsset.transfer(provider, reducedAsset - reward2keeper);
            collateralAsset.transfer(msg.sender, reward2keeper);
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
     * @notice When overallCollateralRatio is below badCollateralRatio, borrowers with collateralRatio below 125% could be fully liquidated.
     * Emits a `LiquidationRecord` event.
     *
     * Requirements:
     * - Current overallCollateralRatio should be below badCollateralRatio
     * - `onBehalfOf`collateralRatio should be below 125%
     * @dev After Liquidation, borrower's debt is reduced by collateralAmount * etherPrice, deposit is reduced by collateralAmount * borrower's collateralRatio. Keeper gets a liquidation reward of `keeperRatio / borrower's collateralRatio
     */
    function superLiquidation(
        address provider,
        address onBehalfOf,
        uint256 assetAmount
    ) external virtual {
        uint256 assetPrice = getAssetPrice();
        require(
            (totalDepositedAsset * assetPrice * 100) /
                poolTotalEUSDCirculation <
                badCollateralRatio,
            "overallCollateralRatio should below 150%"
        );
        uint256 onBehalfOfCollateralRatio = (depositedAsset[onBehalfOf] *
            assetPrice *
            100) / borrowed[onBehalfOf];
        require(
            onBehalfOfCollateralRatio < 125 * 1e18,
            "borrowers collateralRatio should below 125%"
        );
        require(
            assetAmount <= depositedAsset[onBehalfOf],
            "total of collateral can be liquidated at most"
        );
        uint256 eusdAmount = (assetAmount * assetPrice) / 1e18;
        if (onBehalfOfCollateralRatio >= 1e20) {
            eusdAmount = (eusdAmount * 1e20) / onBehalfOfCollateralRatio;
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
            onBehalfOfCollateralRatio >=
            1e20 + configurator.vaultKeeperRatio(address(this)) * 1e18
        ) {
            reward2keeper =
                ((assetAmount * configurator.vaultKeeperRatio(address(this))) *
                    1e18) /
                onBehalfOfCollateralRatio;
            collateralAsset.transfer(msg.sender, reward2keeper);
        }
        collateralAsset.transfer(provider, assetAmount - reward2keeper);

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
    function excessIncomeDistribution(uint256 payAmount) external virtual;

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
    ) external virtual {
        require(
            configurator.isRedemptionProvider(provider),
            "provider is not a RedemptionProvider"
        );
        require(
            borrowed[provider] >= eusdAmount,
            "eusdAmount cannot surpass providers debt"
        );
        uint256 assetPrice = getAssetPrice();
        uint256 providerCollateralRatio = (depositedAsset[provider] *
            assetPrice *
            100) / borrowed[provider];
        require(
            providerCollateralRatio >= 100 * 1e18,
            "provider's collateral ratio should more than 100%"
        );
        _repay(msg.sender, provider, eusdAmount);
        uint256 collateralAmount = (((eusdAmount * 1e18) / assetPrice) *
            (10000 - configurator.redemptionFee())) / 10000;
        depositedAsset[provider] -= collateralAmount;
        totalDepositedAsset -= collateralAmount;
        collateralAsset.transfer(msg.sender, collateralAmount);
        emit RigidRedemption(
            msg.sender,
            provider,
            eusdAmount,
            collateralAmount,
            block.timestamp
        );
    }

    /**
     * @dev Refresh LBR reward before adding providers debt. Refresh Lybra generated service fee before adding totalSupply. Check providers collateralRatio cannot below `safeCollateralRatio`after minting.
     */
    function _mintEUSD(
        address _provider,
        address _onBehalfOf,
        uint256 _mintAmount,
        uint256 _assetPrice
    ) internal virtual;

    /**
     * @notice Burn _provideramount EUSD to payback minted EUSD for _onBehalfOf.
     *
     * @dev Refresh LBR reward before reducing providers debt. Refresh Lybra generated service fee before reducing totalEUSDCirculation.
     */
    function _repay(
        address _provider,
        address _onBehalfOf,
        uint256 _amount
    ) internal virtual {
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
     * @dev Get USD value of current collateral asset and minted EUSD through price oracle / Collateral asset USD value must higher than safe Collateral Ratio.
     */
    function _checkHealth(address _user, uint256 _assetPrice) internal view {
        if (
            ((depositedAsset[_user] * _assetPrice * 100) / borrowed[_user]) <
            configurator.getSafeCollateralRatio(address(this))
        ) revert("collateralRatio is Below safeCollateralRatio");
    }

    function _saveReport() internal {
        feeStored += _newFee();
        lastReportTime = block.timestamp;
    }

    function _newFee() internal view returns (uint256) {
        return
            (poolTotalEUSDCirculation *
                configurator.vaultMintFeeApy(address(this)) *
                (block.timestamp - lastReportTime)) /
            (86400 * 365) /
            10000;
    }

    function getBorrowedOf(address user) external view returns (uint256) {
        return borrowed[user];
    }

    function getPoolTotalEUSDCirculation() external view returns (uint256) {
        return poolTotalEUSDCirculation;
    }

    function getAsset() external view virtual returns (address) {
        return address(collateralAsset);
    }

    function getVaultType() external pure returns (uint8) {
        return vaultType;
    }

    function getAssetPrice() public virtual returns (uint256) {}
}
