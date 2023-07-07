// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

interface IPeUSD {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function convertToPeUSD(address user, uint256 eusdAmount) external;
    function mint(
        address to,
        uint256 amount
    ) external returns (bool);
    function burn(
        address account,
        uint256 amount
    ) external returns (bool);
}
