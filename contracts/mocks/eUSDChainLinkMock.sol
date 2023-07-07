// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract eUSDChainLinkMock {
    uint256 price = 102*1e6;

    function setPrice(uint256 _price) external {
        price = _price;
    }
    function latestRoundData() external view returns(uint80, int, uint, uint, uint80) {
        return (0, int(price), 0,0,0);
    }
}