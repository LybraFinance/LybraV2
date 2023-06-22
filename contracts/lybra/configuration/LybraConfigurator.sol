// SPDX-License-Identifier: BUSL-1.1

/**
 * @title Lybra Protocol V2 Configurator Contract
 * @dev The Configurator contract is used to set various parameters and control functionalities of the Lybra Protocol. It is based on OpenZeppelin's Proxy and AccessControl libraries, allowing the DAO to control contract upgrades. There are three types of governance roles:
 * * DAO: A time-locked contract initiated by esLBR voting, with a minimum effective period of 14 days. After the vote is passed, only the developer can execute the action.
 * * TIMELOCK: A time-locked contract controlled by the developer, with a minimum effective period of 2 days.
 * * ADMIN: A multisignature account controlled by the developer.
 * All setting functions have three levels of calling permissions:
 * * onlyRole(DAO): Only callable by the DAO for governance purposes.
 * * checkRole(TIMELOCK): Callable by both the DAO and the TIMELOCK contract.
 * * checkRole(ADMIN): Callable by all governance roles.
 */

pragma solidity ^0.8.17;

import "../interfaces/IGovernanceTimelock.sol";
import "../interfaces/IEUSD.sol";

interface IProtocolRewardsPool {
    function notifyRewardAmount(uint256 amount, uint256 tokenType) external;
}

interface IeUSDMiningIncentives {
    function refreshReward(address user) external;
}

interface IVault {
    function vaultType() external view returns (uint8);
}

interface ICurvePool{
    function get_dy_underlying(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns(uint256);
}

contract Configurator {
    mapping(address => bool) public mintVault;
    mapping(address => uint256) public mintVaultMaxSupply;
    mapping(address => bool) public vaultMintPaused;
    mapping(address => bool) public vaultBurnPaused;
    mapping(address => uint256) vaultSafeCollateralRatio;
    mapping(address => uint256) vaultBadCollateralRatio;
    mapping(address => uint256) public vaultMintFeeApy;
    mapping(address => uint256) public vaultKeeperRatio;
    mapping(address => bool) redemptionProvider;
    mapping(address => bool) public tokenMiner;

    uint256 public redemptionFee = 50;
    IGovernanceTimelock public GovernanceTimelock;

    IeUSDMiningIncentives public eUSDMiningIncentives;
    IProtocolRewardsPool public lybraProtocolRewardsPool;
    IEUSD public EUSD;
    uint256 public flashloanFee = 500;
    // Limiting the maximum percentage of eUSD that can be cross-chain transferred to L2 in relation to the total supply.
    uint256 maxStableRatio = 5_000;
    address public stableToken;
    ICurvePool public curvePool;
    bool public premiumTradingEnabled;

    event RedemptionFeeChanged(uint256 newSlippage);
    event SafeCollateralRatioChanged(address indexed pool, uint256 newRatio);
    event RedemptionProvider(address indexed user, bool status);
    event ProtocolRewardsPoolChanged(address indexed pool, uint256 timestamp);
    event EUSDMiningIncentivesChanged(address indexed pool, uint256 timestamp);
    event BorrowApyChanged(address indexed pool, uint256 newApy);
    event KeeperRatioChanged(address indexed pool, uint256 newSlippage);
    event tokenMinerChanges(address indexed pool, bool status);

    /// @notice Emitted when the fees for flash loaning a token have been updated
    /// @param fee The new fee for this token as a percentage and multiplied by 100 to avoid decimals (for example, 10% is 10_00)
    event FlashloanFeeUpdated(uint256 fee);

    bytes32 public constant DAO = keccak256("DAO");
    bytes32 public constant TIMELOCK = keccak256("TIMELOCK");
    bytes32 public constant ADMIN = keccak256("ADMIN");

    constructor(address _dao, address _curvePool) {
        GovernanceTimelock = IGovernanceTimelock(_dao);
        curvePool = ICurvePool(_curvePool);
    }

    modifier onlyRole(bytes32 role) {
        GovernanceTimelock.checkOnlyRole(role, msg.sender);
        _;
    }

    modifier checkRole(bytes32 role) {
        GovernanceTimelock.checkRole(role, msg.sender);
        _;
    }

    /**
     * @notice Initializes the eUSD address. This function can only be executed once.
     */
    function initEUSD(address _eusd) external onlyRole(DAO) {
        if (address(EUSD) == address(0)) EUSD = IEUSD(_eusd);
    }

    /**
     * @notice Controls the activation of a specific eUSD vault.
     * @param pool The address of the asset pool.
     * @param isActive A boolean indicating whether to activate or deactivate the vault.
     * @dev This function can only be called by the DAO.
     */
    function setMintVault(address pool, bool isActive) external onlyRole(DAO) {
        mintVault[pool] = isActive;
    }

    /**
     * @notice Controls the minting limit of eUSD for an asset pool.
     * @param pool The address of the asset pool.
     * @param maxSupply The maximum amount of eUSD that can be minted for the asset pool.
     * @dev This function can only be called by the DAO.
     */
    function setMintVaultMaxSupply(address pool, uint256 maxSupply) external onlyRole(DAO) {
        mintVaultMaxSupply[pool] = maxSupply;
    }

    /**
     * @notice  badCollateralRatio can be decided by DAO,starts at 130%
     */
    function setBadCollateralRatio(address pool, uint256 newRatio) external onlyRole(DAO) {
        require(newRatio >= 130 * 1e18 && newRatio <= 150 * 1e18 && newRatio <= vaultSafeCollateralRatio[pool] + 1e19, "LNA");
        vaultBadCollateralRatio[pool] = newRatio;
        emit SafeCollateralRatioChanged(pool, newRatio);
    }

    /**
     * @notice Sets the address of the protocol rewards pool.
     * @param addr The new address of the protocol rewards pool.
     * @dev This function can only be called by accounts with TIMELOCK or higher privilege.
     */
    function setProtocolRewardsPool(address addr) external checkRole(TIMELOCK) {
        lybraProtocolRewardsPool = IProtocolRewardsPool(addr);
        emit ProtocolRewardsPoolChanged(addr, block.timestamp);
    }

    /**
     * @notice Sets the address of the eUSDMiningIncentives pool.
     * @param addr The new address of the eUSDMiningIncentives pool.
     * @dev This function can only be called by accounts with TIMELOCK or higher privilege.
     */
    function setEUSDMiningIncentives(address addr) external checkRole(TIMELOCK) {
        eUSDMiningIncentives = IeUSDMiningIncentives(addr);
        emit EUSDMiningIncentivesChanged(addr, block.timestamp);
    }

    /**
     * @notice Enables or disables the repayment functionality for a asset pool.
     * @param pool The address of the pool.
     * @param isActive Boolean value indicating whether repayment is active or paused.
     * @dev This function can only be called by accounts with TIMELOCK or higher privilege.
     */
    function setvaultBurnPaused(address pool, bool isActive) external checkRole(TIMELOCK) {
        vaultBurnPaused[pool] = isActive;
    }

    /**
     * @notice Sets the status of premium trading.
     * @param isActive Boolean value indicating whether premium trading is enabled or disabled.
     * @dev This function can only be called by accounts with TIMELOCK or higher privilege.
     */
    function setPremiumTradingEnabled(bool isActive) external checkRole(TIMELOCK) {
        premiumTradingEnabled = isActive;
    }

    /**
     * @notice Enables or disables the mint functionality for a asset pool.
     * @param pool The address of the pool.
     * @param isActive Boolean value indicating whether minting is active or paused.
     * @dev This function can only be called by accounts with ADMIN or higher privilege.
     */
    function setvaultMintPaused(address pool, bool isActive) external checkRole(ADMIN) {
        vaultMintPaused[pool] = isActive;
    }

    /**
     * @notice Sets the redemption fee.
     * @param newFee The new fee to be set.
     * @notice The fee cannot exceed 5%.
     */
    function setRedemptionFee(uint256 newFee) external checkRole(TIMELOCK) {
        require(newFee <= 500, "Max Redemption Fee is 5%");
        redemptionFee = newFee;
        emit RedemptionFeeChanged(newFee);
    }

    /**
     * @notice  safeCollateralRatio can be decided by TIMELOCK.
     * The eUSD vault requires a minimum safe collateral rate of 160%,
     * On the other hand, the PeUSD vault requires a safe collateral rate at least 10% higher
     * than the liquidation collateral rate, providing an additional buffer to protect against liquidation risks.
     */
    function setSafeCollateralRatio(address pool, uint256 newRatio) external checkRole(TIMELOCK) {
        if(IVault(pool).vaultType() == 0) {
            require(newRatio >= 160 * 1e18, "eUSD vault safe collateralRatio should more than 160%");
        } else {
            require(newRatio >= vaultBadCollateralRatio[pool] + 1e19, "PeUSD vault safe collateralRatio should more than bad collateralRatio");
        }
        vaultSafeCollateralRatio[pool] = newRatio;
        emit SafeCollateralRatioChanged(pool, newRatio);
    }

    /**
     * @notice  Set the borrowing annual percentage yield (APY) for a asset pool.
     * @param pool The address of the pool to set the borrowing APY for.
     * @param newApy The new borrowing APY to set, limited to a maximum of 2%.
     */
    function setBorrowApy(address pool, uint256 newApy) external checkRole(TIMELOCK) {
        require(newApy <= 200, "Borrow APY cannot exceed 2%");
        vaultMintFeeApy[pool] = newApy;
        emit BorrowApyChanged(pool, newApy);
    }

    /**
     * @notice Set the reward ratio for the liquidator after liquidation.
     * @param pool The address of the pool to set the reward ratio for.
     * @param newRatio The new reward ratio to set, limited to a maximum of 5%.
     */
    function setKeeperRatio(address pool,uint256 newRatio) external checkRole(TIMELOCK) {
        require(newRatio <= 5, "Max Keeper reward is 5%");
        vaultKeeperRatio[pool] = newRatio;
        emit KeeperRatioChanged(pool, newRatio);
    }

    /**
     * @notice Sets the mining permission for the esLBR&LBR mining pool.
     * @param _contracts An array of addresses representing the contracts.
     * @param _bools An array of booleans indicating whether mining is allowed for each contract.
     */
    function setTokenMiner(address[] calldata _contracts, bool[] calldata _bools) external checkRole(TIMELOCK) {
        for (uint256 i = 0; i < _contracts.length; i++) {
            tokenMiner[_contracts[i]] = _bools[i];
            emit tokenMinerChanges(_contracts[i], _bools[i]);
        }
    }

    /**
     * dev Sets the maximum percentage share for PeUSD.
     * @param _ratio The ratio in basis points (1/10_000). The maximum value is 10_000.
     */
    function setMaxStableRatio(uint256 _ratio) external checkRole(TIMELOCK) {
        require(_ratio <= 10_000, "The maximum value is 10000");
        maxStableRatio = _ratio;
    }

    /// @notice Update the flashloan fee percentage, only available to the manager of the contract
    /// @param fee The fee percentage for eUSD, multiplied by 100 (for example, 10% is 1000)
    function setFlashloanFee(uint256 fee) external checkRole(TIMELOCK) {
        if (fee > 10_000) revert('EL');
        emit FlashloanFeeUpdated(fee);
        flashloanFee = fee;
    }

    /// @notice Sets the address of the stablecoin used for rewards distribution.
    /// @param _token The address of the stablecoin token.
    function setProtocolRewardsToken(address _token) external checkRole(TIMELOCK) {
        stableToken = _token;
    }

    /**
     * @notice User chooses to become a Redemption Provider
     */
    function becomeRedemptionProvider(bool _bool) external {
        eUSDMiningIncentives.refreshReward(msg.sender);
        redemptionProvider[msg.sender] = _bool;
        emit RedemptionProvider(msg.sender, _bool);
    }

    /**
     * @dev Updates the mining data for the user's eUSD mining incentives.
     */
    function refreshMintReward(address user) external {
        eUSDMiningIncentives.refreshReward(user);
    }
    
    /**
     * @notice Distributes rewards to the LybraProtocolRewardsPool based on the available balance of eUSD.
     * If the balance is greater than 1e21, the distribution process is triggered.
     * If premiumTradingEnabled is false or the price of the trading pair (0, 2) on the Curve pool is less than or equal to 1005000, eUSD rewards are directly transferred to the LybraProtocolRewardsPool.
     * Otherwise, a controlled premium trading is performed by exchanging eUSD for the third token in the trading pair on the Curve pool, using a calculated amount to maintain a premium.
     * The resulting token amount is transferred to the LybraProtocolRewardsPool.
     * @dev The protocol rewards amount is notified to the LybraProtocolRewardsPool for proper reward allocation.
     */
    function distributeRewards() external {
        uint256 balance = EUSD.balanceOf(address(this));
        if (balance > 1e21) {
            uint256 price = curvePool.get_dy_underlying(0, 2, 1e18);
            if(!premiumTradingEnabled || price <= 1005000) {
                EUSD.transfer(address(lybraProtocolRewardsPool), balance);
                lybraProtocolRewardsPool.notifyRewardAmount(balance, 0);
            } else {
                EUSD.approve(address(curvePool), balance);
                uint256 amount = curvePool.exchange_underlying(0, 2, balance, balance * price * 998 / 1e21);
                IEUSD(stableToken).transfer(address(lybraProtocolRewardsPool), amount);
                lybraProtocolRewardsPool.notifyRewardAmount(amount, 1);
            }
        }
    }

    /**
     * @dev Returns the address of the eUSD token.
     * @return The address of the eUSD token.
     */
    function getEUSDAddress() external view returns (address) {
        return address(EUSD);
    }

    /**
     * @dev Returns the address of the Lybra protocol rewards pool.
     * @return The address of the Lybra protocol rewards pool.
     */
    function getProtocolRewardsPool() external view returns (address) {
        return address(lybraProtocolRewardsPool);
    }

    /**
     * @dev Returns the safe collateral ratio for a asset pool.
     * @param pool The address of the pool to check.
     * @return The safe collateral ratio for the specified pool.
     */
    function getSafeCollateralRatio(
        address pool
    ) external view returns (uint256) {
        if (vaultSafeCollateralRatio[pool] == 0) return 160 * 1e18;
        return vaultSafeCollateralRatio[pool];
    }

    function getBadCollateralRatio(address pool) external view returns(uint256) {
        if(vaultBadCollateralRatio[pool] == 0) return vaultSafeCollateralRatio[pool] - 1e19;
        return vaultBadCollateralRatio[pool];
    }

    /**
     * @dev Checks if a user is a redemption provider.
     * @param user The address of the user to check.
     * @return True if the user is a redemption provider, false otherwise.
     */
    function isRedemptionProvider(address user) external view returns (bool) {
        return redemptionProvider[user];
    }

    /**
     * @dev Return the maximum quantity of PeUSD that can be minted by using eUSD.
     * @return The maximum quantity of PeUSD that can be minted through eUSD.
     */
    function getEUSDMaxLocked() external view returns (uint256) {
        return (EUSD.totalSupply() * maxStableRatio) / 10_000;
    }

    function hasRole(bytes32 role, address caller) external view returns (bool) {
        return GovernanceTimelock.checkRole(role, caller);
    }
}
