// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "../interfaces/IEUSD.sol";
import "./base/LybraPeUSDVaultBase.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IRETH {
    function getExchangeRate() external view returns (uint256);
}

interface IRocketDepositPool {
    function deposit() external payable;
}
interface IRocketStorageInterface {
    function getAddress(bytes32 _key) external view returns (address);
}

contract LybraRETHVault is LybraPeUSDVaultBase {
    IRocketStorageInterface immutable rocketStorage;

    // _rocketStorageAddress = 0x1d8f8f00cfa6758d7bE78336684788Fb0ee0Fa46
    // _rETH = 0xae78736Cd615f374D3085123A210448E74Fc6393
    constructor(address _rocketStorageAddress, address _rETH, address _oracle, address _config)
        LybraPeUSDVaultBase(_rETH, _oracle, _config) {
        rocketStorage = IRocketStorageInterface(_rocketStorageAddress);
    }

    function depositEtherToMint(uint256 mintAmount) external payable override {
        require(msg.value >= 1 ether, "DNL");
        uint256 preBalance = collateralAsset.balanceOf(address(this));
        IRocketDepositPool(rocketStorage.getAddress(keccak256(abi.encodePacked("contract.address", "rocketDepositPool")))).deposit{value: msg.value}();
        uint256 balance = collateralAsset.balanceOf(address(this));
        depositedAsset[msg.sender] += balance - preBalance;

        if (mintAmount > 0) {
            _mintPeUSD(msg.sender, msg.sender, mintAmount, getAssetPrice());
        }

        emit DepositEther(msg.sender, address(collateralAsset), msg.value,balance - preBalance, block.timestamp);
    }

    function getAssetPrice() public override returns (uint256) {
        return (_etherPrice() * IRETH(address(collateralAsset)).getExchangeRate()) / 1e18;
    }

    function getAsset2EtherExchangeRate() external view override returns (uint256) {
        return IRETH(address(collateralAsset)).getExchangeRate();
    }
}
