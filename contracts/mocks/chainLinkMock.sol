// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

contract mockChainlink is Ownable {
    uint256 price = 1600*1e8;

    function setPrice(uint256 _price) external onlyOwner {
        price = _price;
    }
    function latestRoundData() external view returns(uint80, int, uint, uint, uint80) {
        return (0, int(price), 0,0,0);
    }
}