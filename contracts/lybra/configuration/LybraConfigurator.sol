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

interface DividendPool {
    function notifyRewardAmount(uint256 amount) external;
}

interface IeUSDMiningIncentives {
    function refreshReward(address user) external;
}

interface IVault {
    function vaultType() external view returns (uint8);
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
    DividendPool public lybraDividendPool;
    IEUSD public EUSD;
    uint256 public flashloanFee = 500;
    // Limiting the maximum percentage of eUSD that can be cross-chain transferred to L2 in relation to the total supply.
    uint256 maxStableRatio = 5_000;

    event RedemptionFeeChanged(uint256 newSlippage);
    event SafeCollateralRatioChanged(address indexed pool, uint256 newRatio);
    event RedemptionProvider(address indexed user, bool status);
    event DividendPoolChanged(address indexed pool, uint256 timestamp);
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

    /// @notice Thrown when trying to update token fees to an invalid percentage
    error InvalidPercentage();

    constructor(address _dao) {
        GovernanceTimelock = IGovernanceTimelock(_dao);
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
    function setmintVault(address pool, bool isActive) external onlyRole(DAO) {
        mintVault[pool] = isActive;
    }

    /**
     * @notice Controls the minting limit of eUSD for an asset pool.
     * @param pool The address of the asset pool.
     * @param maxSupply The maximum amount of eUSD that can be minted for the asset pool.
     * @dev This function can only be called by the DAO.
     */
    function setmintVaultMaxSupply(
        address pool,
        uint256 maxSupply
    ) external onlyRole(DAO) {
        mintVaultMaxSupply[pool] = maxSupply;
    }

    /**
     * @notice  badCollateralRatio can be decided by DAO,starts at 120%
     */
    function setBadCollateralRatio(
        address pool,
        uint256 newRatio
    ) external onlyRole(DAO) {
        require(
            newRatio >= 120 * 1e18 && newRatio <= vaultSafeCollateralRatio[pool] + 1e19,
            "Safe CollateralRatio should more than 160%"
        );
        vaultBadCollateralRatio[pool] = newRatio;
        emit SafeCollateralRatioChanged(pool, newRatio);
    }

    /**
     * @notice Sets the address of the dividend pool.
     * @param addr The new address of the dividend pool.
     * @dev This function can only be called by accounts with TIMELOCK or higher privilege.
     */
    function setDividendPool(address addr) external checkRole(TIMELOCK) {
        lybraDividendPool = DividendPool(addr);
        emit DividendPoolChanged(addr, block.timestamp);
    }

    /**
     * @notice Sets the address of the eUSDMiningIncentives pool.
     * @param addr The new address of the eUSDMiningIncentives pool.
     * @dev This function can only be called by accounts with TIMELOCK or higher privilege.
     */
    function setEUSDMiningIncentives(
        address addr
    ) external checkRole(TIMELOCK) {
        eUSDMiningIncentives = IeUSDMiningIncentives(addr);
        emit EUSDMiningIncentivesChanged(addr, block.timestamp);
    }

    /**
     * @notice Enables or disables the repayment functionality for a asset pool.
     * @param pool The address of the pool.
     * @param isActive Boolean value indicating whether repayment is active or paused.
     * @dev This function can only be called by accounts with TIMELOCK or higher privilege.
     */
    function setvaultBurnPaused(
        address pool,
        bool isActive
    ) external checkRole(TIMELOCK) {
        vaultBurnPaused[pool] = isActive;
    }

    /**
     * @notice Enables or disables the mint functionality for a asset pool.
     * @param pool The address of the pool.
     * @param isActive Boolean value indicating whether minting is active or paused.
     * @dev This function can only be called by accounts with ADMIN or higher privilege.
     */
    function setvaultMintPaused(
        address pool,
        bool isActive
    ) external checkRole(ADMIN) {
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
    function setSafeCollateralRatio(
        address pool,
        uint256 newRatio
    ) external checkRole(TIMELOCK) {
        if(IVault(pool).vaultType() == 0) {
            require(
                newRatio >= 160 * 1e18,
                "eUSD vault safe collateralRatio should more than 160%"
            );
        } else {
            require(
                newRatio >= vaultBadCollateralRatio[pool] + 1e19,
                "PeUSD vault safe collateralRatio should more than bad collateralRatio"
            );
        }
        vaultSafeCollateralRatio[pool] = newRatio;
        emit SafeCollateralRatioChanged(pool, newRatio);
    }

    /**
     * @notice  Set the borrowing annual percentage yield (APY) for a asset pool.
     * @param pool The address of the pool to set the borrowing APY for.
     * @param newApy The new borrowing APY to set, limited to a maximum of 2%.
     */
    function setBorrowApy(
        address pool,
        uint256 newApy
    ) external checkRole(TIMELOCK) {
        require(newApy <= 200, "Borrow APY cannot exceed 2%");
        vaultMintFeeApy[pool] = newApy;
        emit BorrowApyChanged(pool, newApy);
    }

    /**
     * @notice Set the reward ratio for the liquidator after liquidation.
     * @param pool The address of the pool to set the reward ratio for.
     * @param newRatio The new reward ratio to set, limited to a maximum of 5%.
     */
    function setKeeperRatio(
        address pool,
        uint256 newRatio
    ) external checkRole(TIMELOCK) {
        require(newRatio <= 5, "Max Keeper reward is 5%");
        vaultKeeperRatio[pool] = newRatio;
        emit KeeperRatioChanged(pool, newRatio);
    }

    /**
     * @notice Sets the mining permission for the esLBR&LBR mining pool.
     * @param _contracts An array of addresses representing the contracts.
     * @param _bools An array of booleans indicating whether mining is allowed for each contract.
     */
    function setTokenMiner(
        address[] calldata _contracts,
        bool[] calldata _bools
    ) external checkRole(TIMELOCK) {
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
        if (fee > 10_000) revert InvalidPercentage();
        emit FlashloanFeeUpdated(fee);
        flashloanFee = fee;
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
     * @dev Distributes the temporarily held eUSD fees to the esLBR holders.
     * @dev Requires the eUSD balance in the contract to be greater than 1000.
     */
    function distributeDividends() external {
        uint256 balance = EUSD.balanceOf(address(this));
        if (balance > 1e21) {
            EUSD.transfer(address(lybraDividendPool), balance);
            lybraDividendPool.notifyRewardAmount(balance);
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
     * @dev Returns the address of the Lybra dividend pool.
     * @return The address of the Lybra dividend pool.
     */
    function getDividendPool() external view returns (address) {
        return address(lybraDividendPool);
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
        if(vaultBadCollateralRatio[pool] == 0) return vaultSafeCollateralRatio[pool] + 1e19;
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
     * @dev Returns the maximum supply of PeUSD based on the eUSD total supply and the maximum stable ratio.
     * @return The maximum supply of PeUSD.
     */
    function getPeUSDMaxSupply() external view returns (uint256) {
        return (EUSD.totalSupply() * maxStableRatio) / 10_000;
    }

    function hasRole(
        bytes32 role,
        address caller
    ) external view returns (bool) {
        return GovernanceTimelock.checkOnlyRole(role, caller);
    }
}
