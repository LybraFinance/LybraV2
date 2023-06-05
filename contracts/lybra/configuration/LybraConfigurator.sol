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

import "../governance/governance.sol";
import "../interfaces/IEUSD.sol";

interface DividendPool {
    function notifyRewardAmount(uint256 amount) external;
}

interface IeUSDMiningIncentives {
    function refreshReward(address user) external;
}

contract Configurator is Governance {
    mapping(address => bool) public mintPool;
    mapping(address => uint256) public mintPoolMaxSupply;
    mapping(address => bool) public poolMintPaused;
    mapping(address => bool) public poolBurnPaused;
    mapping(address => uint256) poolSafeCollateralRate;
    mapping(address => uint256) public poolMintFeeApy;
    mapping(address => uint256) public poolKeeperRate;
    mapping(address => bool) redemptionProvider;
    mapping(address => bool) public esLBRMiner;

    // uint256 public safeCollateralRate = 160 * 1e18;
    uint256 public immutable badCollateralRate = 150 * 1e18;
    uint256 public redemptionFee = 50;

    IeUSDMiningIncentives public eUSDMiningIncentives;
    DividendPool public lybraDividendPool;
    IEUSD public EUSD;
    uint256 public flashloanFee = 500;
    // Limiting the maximum percentage of eUSD that can be cross-chain transferred to L2 in relation to the total supply.
    uint256 maxStableRatio = 5_000;

    event RedemptionFeeChanged(uint256 newSlippage);
    event SafeCollateralRateChanged(address indexed pool, uint256 newRatio);
    event RedemptionProvider(address indexed user, bool status);
    event DividendPoolChanged(address indexed pool, uint256 timestamp);
    event EUSDMiningIncentivesChanged(address indexed pool, uint256 timestamp);
    event BorrowApyChanged(address indexed pool, uint256 newApy);
    event KeeperRateChanged(address indexed pool, uint256 newSlippage);
    event esLBRMinerChanges(address indexed pool, bool status);

    /// @notice Emitted when the fees for flash loaning a token have been updated
	/// @param fee The new fee for this token as a percentage and multiplied by 100 to avoid decimals (for example, 10% is 10_00)
	event FlashloanFeeUpdated(uint256 fee);


    /// @notice Thrown when trying to update token fees to an invalid percentage
	error InvalidPercentage();
   

    constructor(address _dao) Governance(_dao) {

    }

    /**
     * @notice Initializes the eUSD address. This function can only be executed once.
     */
    function initEUSD(address _eusd) external onlyRole(DAO){
        if(address(EUSD) == address(0)) EUSD = IEUSD(_eusd);
    }

    /**
     * @notice Controls the activation of a specific eUSD vault.
     * @param pool The address of the asset pool.
     * @param isActive A boolean indicating whether to activate or deactivate the vault.
     * @dev This function can only be called by the DAO.
     */
    function setMintPool(address pool, bool isActive) external onlyRole(DAO){
        mintPool[pool] = isActive;
    }

    /**
     * @notice Controls the minting limit of eUSD for an asset pool.
     * @param pool The address of the asset pool.
     * @param maxSupply The maximum amount of eUSD that can be minted for the asset pool.
     * @dev This function can only be called by the DAO.
     */
    function setMintPoolMaxSupply(address pool, uint256 maxSupply) external onlyRole(DAO){
        mintPoolMaxSupply[pool] = maxSupply;
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
    function setPoolBurnPaused(address pool, bool isActive) external checkRole(TIMELOCK){
        poolBurnPaused[pool] = isActive;
    }

    /**
     * @notice Enables or disables the mint functionality for a asset pool.
     * @param pool The address of the pool.
     * @param isActive Boolean value indicating whether minting is active or paused.
     * @dev This function can only be called by accounts with ADMIN or higher privilege.
     */
    function setPoolMintPaused(address pool, bool isActive) external checkRole(ADMIN){
        poolMintPaused[pool] = isActive;
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
     * @notice  safeCollateralRate can be decided by TIMELOCK,starts at 160%
     */
    function setSafeCollateralRate(address pool, uint256 newRatio) external checkRole(TIMELOCK) {
        require(
            newRatio >= 160 * 1e18,
            "Safe CollateralRate should more than 160%"
        );
        poolSafeCollateralRate[pool] = newRatio;
        emit SafeCollateralRateChanged(pool, newRatio);
    }

    /**
     * @notice  Set the borrowing annual percentage yield (APY) for a asset pool.
     * @param pool The address of the pool to set the borrowing APY for.
     * @param newApy The new borrowing APY to set, limited to a maximum of 2%.
     */
    function setBorrowApy(address pool, uint256 newApy) external checkRole(TIMELOCK) {
        require(newApy <= 200, "Borrow APY cannot exceed 2%");
        poolMintFeeApy[pool] = newApy;
        emit BorrowApyChanged(pool, newApy);
    }

    /**
     * @notice Set the reward rate for the liquidator after liquidation.
     * @param pool The address of the pool to set the reward rate for.
     * @param newRate The new reward rate to set, limited to a maximum of 5%.
     */
    function setKeeperRate(address pool, uint256 newRate) external checkRole(TIMELOCK) {
        require(newRate <= 5, "Max Keeper reward is 5%");
        poolKeeperRate[pool] = newRate;
        emit KeeperRateChanged(pool, newRate);
    }

    /**
     * @notice Sets the mining permission for the esLBR mining pool.
     * @param _contracts An array of addresses representing the contracts.
     * @param _bools An array of booleans indicating whether mining is allowed for each contract.
     */
    function setEsLBRMiner(address[] calldata _contracts, bool[] calldata _bools) external checkRole(TIMELOCK) {
        for(uint256 i = 0;i<_contracts.length;i++) {
            esLBRMiner[_contracts[i]] = _bools[i];
            emit esLBRMinerChanges(_contracts[i], _bools[i]);
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
        if(balance > 1e21) {
            EUSD.transfer(address(lybraDividendPool), balance);
            lybraDividendPool.notifyRewardAmount(balance);
        }
    }

    /**
     * @dev Returns the address of the eUSD token.
     * @return The address of the eUSD token.
     */
    function getEUSDAddress() external view returns(address) {
        return address(EUSD);
    }

    /**
     * @dev Returns the address of the Lybra dividend pool.
     * @return The address of the Lybra dividend pool.
     */
    function getDividendPool() external view returns(address) {
        return address(lybraDividendPool);
    }
    
    /**
     * @dev Returns the safe collateral rate for a asset pool.
     * @param pool The address of the pool to check.
     * @return The safe collateral rate for the specified pool.
     */
    function getSafeCollateralRate(address pool) external view returns(uint256) {
        if(poolSafeCollateralRate[pool] == 0) return 160 * 1e18;
        return poolSafeCollateralRate[pool];
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
        return EUSD.totalSupply() * maxStableRatio / 10_000;
    }
}