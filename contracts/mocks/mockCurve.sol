// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract mockCurve {
    uint256 price = 1010000;
    ERC20 eusd;
    ERC20 usdc;

    function setToken(address _eusd, address _usdc) external {
        eusd = ERC20(_eusd);
        usdc = ERC20(_usdc);
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }
    function get_dy_underlying(int128 i, int128 j, uint256 dx) external view returns (uint256) {
        return price;
    }
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns(uint256) {
        eusd.transferFrom(msg.sender, address(this), dx);
        usdc.transfer(msg.sender, min_dy);
        return min_dy;
    }
}