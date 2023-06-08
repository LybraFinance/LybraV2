// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "../interfaces/IEUSD.sol";
import "./base/LybraPeUSDVaultBase.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IWBETH {
    function exchangeRatio() external view returns (uint256);

    function deposit(address referral) external payable;
}

interface IPriceFeed {
    function fetchPrice() external returns (uint256);
}

contract LybraWbETHVault is LybraPeUSDVaultBase {
    constructor(
        address _peusd,
        address _config
    )
        LybraPeUSDVaultBase(
            _peusd,
            0xae78736Cd615f374D3085123A210448E74Fc6393,
            _config
        )
    {}

    function depositEtherToMint(uint256 mintAmount) external payable override {
        require(msg.value >= 1 ether, "DNL");
        uint256 preBalance = collateralAsset.balanceOf(address(this));
        IWBETH(address(collateralAsset)).deposit{value: msg.value}(
            address(configurator)
        );
        uint256 balance = collateralAsset.balanceOf(address(this));
        depositedAsset[msg.sender] += balance - preBalance;

        if (mintAmount > 0) {
            _mintPeUSD(msg.sender, msg.sender, mintAmount, getAssetPrice());
        }

        emit DepositEther(
            msg.sender,
            address(collateralAsset),
            msg.value,
            balance - preBalance,
            block.timestamp
        );
    }

    function getAssetPrice() public override returns (uint256) {
        uint etherPrice = IPriceFeed(0x4c517D4e2C851CA76d7eC94B805269Df0f2201De)
            .fetchPrice();
        return
            (etherPrice * IWBETH(address(collateralAsset)).exchangeRatio()) /
            1e18;
    }
}
