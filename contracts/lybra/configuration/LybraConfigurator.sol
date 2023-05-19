// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "../governance/governance.sol";

interface DividendPool {
    function notifyRewardAmount(uint256 amount) external;
}

interface IeUSDMiningIncentives {
    function refreshReward(address user) external;
}

interface IEUSD {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
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

    event RedemptionFeeChanged(uint256 newSlippage);
    event SafeCollateralRateChanged(address indexed pool, uint256 newRatio);
    event RedemptionProvider(address indexed user, bool status);
    event DividendPoolChanged(address indexed pool, uint256 timestamp);
    event EUSDMiningIncentivesChanged(address indexed pool, uint256 timestamp);
    event BorrowApyChanged(address indexed pool, uint256 newApy);
    event KeeperRateChanged(address indexed pool, uint256 newSlippage);

    constructor(address _dao) Governance(_dao) {

    }

    function initEUSD(address _eusd) external onlyRole(DAO){
        if(address(EUSD) == address(0)) EUSD = IEUSD(_eusd);
    }

    function setMintPool(address pool, bool isActive) external onlyRole(DAO){
        mintPool[pool] = isActive;
    }

    function setMintPoolMaxSupply(address pool, uint256 maxSupply) external onlyRole(DAO){
        mintPoolMaxSupply[pool] = maxSupply;
    }

    function setDividendPool(address addr) external checkRole(TIMELOCK) {
        lybraDividendPool = DividendPool(addr);
        emit DividendPoolChanged(addr, block.timestamp);
    }

    function setEUSDMiningIncentives(address addr) external checkRole(TIMELOCK) {
        eUSDMiningIncentives = IeUSDMiningIncentives(addr);
        emit EUSDMiningIncentivesChanged(addr, block.timestamp);
    }

    function setPoolMintPaused(address pool, bool isActive) external checkRole(ADMIN){
        poolMintPaused[pool] = isActive;
    }

    function setPoolBurnPaused(address pool, bool isActive) external checkRole(TIMELOCK){
        poolBurnPaused[pool] = isActive;
    }

    /**
     * @notice DAO sets RedemptionFee, 100 means 1%
     */
    function setRedemptionFee(uint256 newFee) external checkRole(TIMELOCK) {
        require(newFee <= 500, "Max Redemption Fee is 5%");
        redemptionFee = newFee;
        emit RedemptionFeeChanged(newFee);
    }

    /**
     * @notice  safeCollateralRate can be decided by DAO,starts at 160%
     */
    function setSafeCollateralRate(address pool, uint256 newRatio) external checkRole(TIMELOCK) {
        require(
            newRatio >= 160 * 1e18,
            "Safe CollateralRate should more than 160%"
        );
        poolSafeCollateralRate[pool] = newRatio;
        emit SafeCollateralRateChanged(pool, newRatio);
    }

    function setBorrowApy(address pool, uint256 newApy) external checkRole(TIMELOCK) {
        require(newApy <= 200, "Borrow APY cannot exceed 2%");
        poolMintFeeApy[pool] = newApy;
        emit BorrowApyChanged(pool, newApy);
    }

    /**
     * @notice KeeperRate can be decided by DAO,1 means 1% of revenue
     */
    function setKeeperRate(address pool, uint256 newRate) external checkRole(TIMELOCK) {
        require(newRate <= 5, "Max Keeper reward is 5%");
        poolKeeperRate[pool] = newRate;
        emit KeeperRateChanged(pool, newRate);
    }

    function setMinter(address[] calldata _contracts, bool[] calldata _bools) external checkRole(TIMELOCK) {
        for(uint256 i = 0;i<_contracts.length;i++) {
            esLBRMiner[_contracts[i]] = _bools[i];
        }
    }

    /**
     * @notice User chooses to become a Redemption Provider
     */
    function becomeRedemptionProvider(bool _bool) external {
        eUSDMiningIncentives.refreshReward(msg.sender);
        redemptionProvider[msg.sender] = _bool;
        emit RedemptionProvider(msg.sender, _bool);
    }

    function refreshMintReward(address user) external {
        eUSDMiningIncentives.refreshReward(user);
    }

    function distributeDividends() external {
        uint256 balance = EUSD.balanceOf(address(this));
        if(balance > 1e21) {
            EUSD.transfer(address(lybraDividendPool), balance);
            lybraDividendPool.notifyRewardAmount(balance);
        }
    }

    function getDividendPool() external view returns(address) {
        return address(lybraDividendPool);
    }
    
    function getSafeCollateralRate(address pool) external view returns(uint256) {
        if(poolSafeCollateralRate[pool] == 0) return 160 * 1e18;
        return poolSafeCollateralRate[pool];
    }

    function isRedemptionProvider(address user) external view returns (bool) {
        return redemptionProvider[user];
    }

}