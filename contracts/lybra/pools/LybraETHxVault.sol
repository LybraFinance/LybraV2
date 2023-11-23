// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "../interfaces/IEUSD.sol";
import "./base/LybraPeUSDVaultBase.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IStaderStakePoolsManager {
    function getExchangeRate() external view returns (uint256);

    function deposit(address _receiver) external payable;
}

contract LybraETHxVault is LybraPeUSDVaultBase, ReentrancyGuard {
    IStaderStakePoolsManager immutable staderStakePoolsManager;
    //StaderStakePoolsManager = 0xcf5EA1b38380f6aF39068375516Daf40Ed70D299
    //ETHx = 0xA35b1B31Ce002FBF2058D22F30f95D405200A15b
    constructor(address _staderStakePoolsManager,address _asset, address _oracle, address _config)
        LybraPeUSDVaultBase(_asset, _oracle, _config) {
            staderStakePoolsManager = IStaderStakePoolsManager(_staderStakePoolsManager);
        }

    function depositEtherToMint(uint256 mintAmount) nonReentrant external payable override {
        require(msg.value >= 1 ether, "DNL");
        uint256 preBalance = collateralAsset.balanceOf(address(this));
        staderStakePoolsManager.deposit{value: msg.value}(address(this));
        uint256 balance = collateralAsset.balanceOf(address(this));
        depositedAsset[msg.sender] += balance - preBalance;

        if (mintAmount > 0) {
            _mintPeUSD(msg.sender, msg.sender, mintAmount, getAssetPrice());
        }

        emit DepositEther(msg.sender, address(collateralAsset), msg.value,balance - preBalance, block.timestamp);
    }

    function getAssetPrice() public override returns (uint256) {
        return _etherPrice() * staderStakePoolsManager.getExchangeRate() / 1e18;
    }
    function getAsset2EtherExchangeRate() external view override returns (uint256) {
        return staderStakePoolsManager.getExchangeRate();
    }
}