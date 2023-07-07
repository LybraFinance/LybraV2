// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;
/**
 * @title esLBR is an ERC20-compliant token, but cannot be transferred and can only be minted through the esLBRMinter contract or redeemed for LBR by destruction.
 * - The maximum amount that can be minted through the esLBRMinter contract is 55 million.
 * - esLBR can be used for community governance voting.
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";


interface IesLBR {
    function mint(address user, uint256 amount) external returns(bool);
    function burn(address user, uint256 amount) external returns(bool);
}
contract mockLBRMiner {
    constructor()
    {
    }

    function mint(address token, address to, uint256 amount) external {
        IesLBR(token).mint(to, amount);
    }
    function burn(address token, address to, uint256 amount) external {
        IesLBR(token).burn(to, amount);
    }
}