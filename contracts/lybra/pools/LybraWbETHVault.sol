// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "../interfaces/IEUSD.sol";
import "./base/LybraPeUSDVaultBase.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IWBETH {
    function exchangeRate() external view returns (uint256);

    function deposit(address referral) external payable;
}

contract LybraWBETHVault is LybraPeUSDVaultBase {
    //WBETH = 0xa2e3356610840701bdf5611a53974510ae27e2e1
    constructor(address _asset, address _oracle, address _config)
        LybraPeUSDVaultBase(_asset, _oracle, _config) {}

    function depositEtherToMint(uint256 mintAmount) external payable override {
        require(msg.value >= 1 ether, "DNL");
        uint256 preBalance = collateralAsset.balanceOf(address(this));
        IWBETH(address(collateralAsset)).deposit{value: msg.value}(address(configurator));
        uint256 balance = collateralAsset.balanceOf(address(this));
        depositedAsset[msg.sender] += balance - preBalance;

        if (mintAmount > 0) {
            _mintPeUSD(msg.sender, msg.sender, mintAmount, getAssetPrice());
        }

        emit DepositEther(msg.sender, address(collateralAsset), msg.value,balance - preBalance, block.timestamp);
    }

    function getAssetPrice() public override returns (uint256) {
        return (_etherPrice() * IWBETH(address(collateralAsset)).exchangeRate()) / 1e18;
    }
    function getAsset2EtherExchangeRate() external view override returns (uint256) {
        return IWBETH(address(collateralAsset)).exchangeRate();
    }
}
