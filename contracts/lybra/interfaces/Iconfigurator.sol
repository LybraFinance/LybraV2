// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

interface Iconfigurator {
    function mintPool(address pool) external view returns(bool);
    function mintPoolMaxSupply(address pool) external view returns(uint256);
    function poolMintPaused(address pool) external view returns(bool);
    function poolBurnPaused(address pool) external view returns(bool);
    function esLBRMiner(address pool) external view returns(bool);
    function getSafeCollateralRate(address pool) external view returns(uint256);
    function poolMintFeeApy(address pool) external view returns(uint256);
    function poolKeeperRate(address pool) external view returns(uint256);
    function badCollateralRate() external view returns(uint256);
    function redemptionFee() external view returns(uint256);
    function getDividendPool() external view returns(address);
    function isRedemptionProvider(address user) external view returns (bool);
    function becomeRedemptionProvider(bool _bool) external;
    function refreshMintReward(address user) external;
    function distributeDividends() external;
}