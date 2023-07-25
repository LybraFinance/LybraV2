// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "../../interfaces/Iconfigurator.sol";
import "../../interfaces/IPeUSD.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPriceFeed {
    function fetchPrice() external returns (uint256);
}

abstract contract LybraPeUSDVaultBase {
    using SafeERC20 for IERC20;
    IPeUSD public immutable PeUSD;
    IERC20 public immutable collateralAsset;
    Iconfigurator public immutable configurator;
    uint256 poolTotalCirculation;
    IPriceFeed immutable etherOracle;

    mapping(address => uint256) public depositedAsset;
    mapping(address => uint256) borrowed;
    mapping(address => uint256) feeStored;
    mapping(address => uint256) feeUpdatedAt;

    event DepositEther(address indexed onBehalfOf, address asset, uint256 etherAmount, uint256 assetAmount, uint256 timestamp);

    event DepositAsset(address indexed onBehalfOf, address asset, uint256 amount, uint256 timestamp);
    event WithdrawAsset(address indexed sponsor, address indexed onBehalfOf, address asset, uint256 amount, uint256 timestamp);
    event Mint(address indexed sponsor, address indexed onBehalfOf, uint256 amount, uint256 timestamp);
    event Burn(address indexed sponsor, address indexed onBehalfOf, uint256 amount, uint256 timestamp);
    event LiquidationRecord(address indexed provider, address keeper, address indexed onBehalfOf, uint256 eusdamount, uint256 LiquidateAssetAmount, uint256 keeperReward, bool superLiquidation, uint256 timestamp);

    event RigidRedemption(address indexed caller, address indexed provider, uint256 peusdAmount, uint256 assetAmount, uint256 timestamp);
    event FeeDistribution(address indexed feeAddress, uint256 feeAmount, uint256 timestamp);

    constructor(address _collateral, address _etherOracle, address _configurator) {
        collateralAsset = IERC20(_collateral);
        configurator = Iconfigurator(_configurator);
        PeUSD = IPeUSD(configurator.peUSD());
        etherOracle = IPriceFeed(_etherOracle);
    }

    function totalDepositedAsset() public view virtual returns (uint256) {
        return collateralAsset.balanceOf(address(this));
    }

    function depositEtherToMint(uint256 mintAmount) external payable virtual;

    /**
     * @notice Deposit staked ETH, update the interest distribution, can mint PeUSD directly
     * Emits a `DepositAsset` event.
     *
     * Requirements:
     * - `assetAmount` Must be higher than 0.
     * - `mintAmount` Send 0 if doesn't mint PeUSD
     */
    function depositAssetToMint(uint256 assetAmount, uint256 mintAmount) external virtual {
        require(assetAmount >= 1 ether, "Deposit should not be less than 1 collateral asset.");
        collateralAsset.safeTransferFrom(msg.sender, address(this), assetAmount);

        depositedAsset[msg.sender] += assetAmount;
        if (mintAmount > 0) {
            uint256 assetPrice = getAssetPrice();
            _mintPeUSD(msg.sender, msg.sender, mintAmount, assetPrice);
        }
        emit DepositAsset(msg.sender, address(collateralAsset), assetAmount, block.timestamp);
    }

    /**
     * @notice Withdraw collateral assets to an address
     * Emits a `WithdrawAsset` event.
     *
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `amount` Must be higher than 0.
     *
     * @dev Withdraw stETH. Check user’s collateral ratio after withdrawal, should be higher than `safeCollateralRatio`
     */
    function withdraw(address onBehalfOf, uint256 amount) external virtual {
        require(onBehalfOf != address(0), "TZA");
        require(amount != 0, "ZA");
        _withdraw(msg.sender, onBehalfOf, amount);
    }

    /**
     * @notice The mint amount number of PeUSD is minted to the address
     * Emits a `Mint` event.
     *
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     */
    function mint(address onBehalfOf, uint256 amount) external virtual {
        require(onBehalfOf != address(0), "TZA");
        require(amount != 0, "ZA");
        _mintPeUSD(msg.sender, onBehalfOf, amount, getAssetPrice());
    }

    /**
     * @notice Burn the amount of PeUSD and payback the amount of minted PeUSD
     * Emits a `Burn` event.
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `amount` Must be higher than 0.
     * @dev Calling the internal`_repay`function.
     */
    function burn(address onBehalfOf, uint256 amount) external virtual {
        require(onBehalfOf != address(0), "TZA");
        require(amount != 0, "ZA");
        _repay(msg.sender, onBehalfOf, amount);
    }

    /**
     * @notice Keeper liquidates borrowers whose collateral ratio is below badCollateralRatio, using PeUSD provided by Liquidation Provider.
     *
     * Requirements:
     * - onBehalfOf Collateral Ratio should be below badCollateralRatio
     * - assetAmount should be less than 50% of collateral
     * - provider should authorize Lybra to utilize PeUSD
     * @dev After liquidation, borrower's debt is reduced by assetAmount * assetPrice, collateral is reduced by the assetAmount corresponding to 110% of the value. Keeper gets keeperRatio / 110 of Liquidation Reward and Liquidator gets the remaining stETH.
     */
    function liquidation(address provider, address onBehalfOf, uint256 assetAmount) external virtual {
        uint256 assetPrice = getAssetPrice();
        uint256 onBehalfOfCollateralRatio = (depositedAsset[onBehalfOf] * assetPrice * 100) / getBorrowedOf(onBehalfOf);
        require(onBehalfOfCollateralRatio < configurator.getBadCollateralRatio(address(this)), "Borrowers collateral ratio should below badCollateralRatio");

        require(assetAmount * 2 <= depositedAsset[onBehalfOf], "a max of 50% collateral can be liquidated");
        require(PeUSD.allowance(provider, address(this)) != 0, "provider should authorize to provide liquidation EUSD");
        uint256 peusdAmount = (assetAmount * assetPrice) / 1e18;

        _repay(provider, onBehalfOf, peusdAmount);
        uint256 reducedAsset = assetAmount * 11 / 10;
        depositedAsset[onBehalfOf] -= reducedAsset;
        uint256 reward2keeper;
        if (provider == msg.sender) {
            collateralAsset.safeTransfer(msg.sender, reducedAsset);
        } else {
            reward2keeper = (reducedAsset * configurator.vaultKeeperRatio(address(this))) / 110;
            collateralAsset.safeTransfer(provider, reducedAsset - reward2keeper);
            collateralAsset.safeTransfer(msg.sender, reward2keeper);
        }
        emit LiquidationRecord(provider, msg.sender, onBehalfOf, peusdAmount, reducedAsset, reward2keeper, false, block.timestamp);
    }

    /**
     * @notice Choose a Redemption Provider, Rigid Redeem `peusdAmount` of peUSD and get 1:1 value of collateral
     * Emits a `RigidRedemption` event.
     *
     * *Requirements:
     * - `provider` must be a Redemption Provider
     * - `provider`debt must equal to or above`peusdAmount`
     * @dev Service Fee for rigidRedemption `redemptionFee` is set to 0.5% by default, can be revised by DAO.
     */
    function rigidRedemption(address provider, uint256 peusdAmount) external virtual {
        require(configurator.isRedemptionProvider(provider), "provider is not a RedemptionProvider");
        require(borrowed[provider] >= peusdAmount, "peusdAmount cannot surpass providers debt");
        uint256 assetPrice = getAssetPrice();
        uint256 providerCollateralRatio = (depositedAsset[provider] * assetPrice * 100) / getBorrowedOf(provider);
        require(providerCollateralRatio >= 100 * 1e18, "The provider's collateral ratio should be not less than 100%.");
        _repay(msg.sender, provider, peusdAmount);
        uint256 collateralAmount = (((peusdAmount * 1e18) / assetPrice) * (10_000 - configurator.redemptionFee())) / 10_000;
        depositedAsset[provider] -= collateralAmount;
        collateralAsset.safeTransfer(msg.sender, collateralAmount);
        emit RigidRedemption(msg.sender, provider, peusdAmount, collateralAmount, block.timestamp);
    }

    /**
     * @dev Refresh LBR reward before adding providers debt. Refresh Lybra generated service fee before adding totalSupply. Check providers collateralRatio cannot below `safeCollateralRatio`after minting.
     */
    function _mintPeUSD(address _provider, address _onBehalfOf, uint256 _mintAmount, uint256 _assetPrice) internal virtual {
        require(poolTotalCirculation + _mintAmount <= configurator.mintVaultMaxSupply(address(this)), "ESL");
        _updateFee(_provider);

        configurator.refreshMintReward(_provider);

        borrowed[_provider] += _mintAmount;

        PeUSD.mint(_onBehalfOf, _mintAmount);
        poolTotalCirculation += _mintAmount;
        _checkHealth(_provider, _assetPrice);
        emit Mint(_provider, _onBehalfOf, _mintAmount, block.timestamp);
    }

    /**
     * @notice Burn _provideramount PeUSD to payback minted PeUSD for _onBehalfOf.
     *
     * @dev Refresh LBR reward before reducing providers debt. Refresh Lybra generated service fee before reducing totalPeUSDCirculation.
     */
    function _repay(address _provider, address _onBehalfOf, uint256 _amount) internal virtual {
        configurator.refreshMintReward(_onBehalfOf);
        _updateFee(_onBehalfOf);
        uint256 totalFee = feeStored[_onBehalfOf];
        uint256 amount = borrowed[_onBehalfOf] + totalFee >= _amount ? _amount : borrowed[_onBehalfOf] + totalFee;
        if(amount > totalFee) {
            feeStored[_onBehalfOf] = 0;
            PeUSD.transferFrom(_provider, address(configurator), totalFee);
            PeUSD.burn(_provider, amount - totalFee);
            borrowed[_onBehalfOf] -= amount - totalFee;
            poolTotalCirculation -= amount - totalFee;
        } else {
            feeStored[_onBehalfOf] = totalFee - amount;
            PeUSD.transferFrom(_provider, address(configurator), amount);
        }
        try configurator.distributeRewards() {} catch {}
        emit Burn(_provider, _onBehalfOf, amount, block.timestamp);
    }

    function _withdraw(address _provider, address _onBehalfOf, uint256 _amount) internal virtual {
        require(depositedAsset[_provider] >= _amount, "Withdraw amount exceeds deposited amount.");
        depositedAsset[_provider] -= _amount;
        collateralAsset.safeTransfer(_onBehalfOf, _amount);
        if (getBorrowedOf(_provider) > 0) {
            _checkHealth(_provider, getAssetPrice());
        }
        emit WithdrawAsset(_provider, address(collateralAsset), _onBehalfOf, _amount, block.timestamp);
    }

    /**
     * @dev Get USD value of current collateral asset and minted EUSD through price oracle / Collateral asset USD value must higher than safe Collateral Ratio.
     */
    function _checkHealth(address user, uint256 price) internal view {
        if (((depositedAsset[user] * price * 100) / getBorrowedOf(user)) < configurator.getSafeCollateralRatio(address(this))) 
            revert("collateralRatio is Below safeCollateralRatio");
    }

    function _updateFee(address user) internal {
        if (block.timestamp > feeUpdatedAt[user]) {
            feeStored[user] += _newFee(user);
            feeUpdatedAt[user] = block.timestamp;
        }
    }

    function _newFee(address user) internal view returns (uint256) {
        return (borrowed[user] * configurator.vaultMintFeeApy(address(this)) * (block.timestamp - feeUpdatedAt[user])) / (86_400 * 365) / 10_000;
    }

    /**
     * @dev Return USD value of current ETH through Liquity PriceFeed Contract.
     */
    function _etherPrice() internal returns (uint256) {
        return etherOracle.fetchPrice();
    }

    /**
     * @dev Returns the current borrowing amount for the user, including borrowed shares and accumulated fees.
     * @param user The address of the user.
     * @return The total borrowing amount for the user.
     */
    function getBorrowedOf(address user) public view returns (uint256) {
        return borrowed[user] + feeStored[user] + _newFee(user);
    }

    function getPoolTotalCirculation() external view returns (uint256) {
        return poolTotalCirculation;
    }

    function getAsset() external view returns (address) {
        return address(collateralAsset);
    }

    function getVaultType() external pure returns (uint8) {
        return 1;
    }

    function getAssetPrice() public virtual returns (uint256);
    function getAsset2EtherExchangeRate() external view virtual returns (uint256);
}
