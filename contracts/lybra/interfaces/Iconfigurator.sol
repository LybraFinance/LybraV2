// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

interface Iconfigurator {
    function mintVault(address pool) external view returns(bool);
    function mintVaultMaxSupply(address pool) external view returns(uint256);
    function vaultMintPaused(address pool) external view returns(bool);
    function vaultBurnPaused(address pool) external view returns(bool);
    function tokenMiner(address pool) external view returns(bool);
    function getSafeCollateralRate(address pool) external view returns(uint256);
    function getBadCollateralRate(address pool) external view returns(uint256);
    function vaultMintFeeApy(address pool) external view returns(uint256);
    function vaultKeeperRate(address pool) external view returns(uint256);
    function redemptionFee() external view returns(uint256);
    function getEUSDAddress() external view returns(address);
    function eUSDMiningIncentives() external view returns(address);
    function getDividendPool() external view returns(address);
    function flashloanFee() external view returns(uint256);
    function getEUSDMaxLocked() external view returns (uint256);
    function isRedemptionProvider(address user) external view returns (bool);
    function becomeRedemptionProvider(bool _bool) external;
    function refreshMintReward(address user) external;
    function distributeDividends() external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}