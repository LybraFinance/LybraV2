// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;
/**
 * @title esLBR is an ERC20-compliant token, but cannot be transferred and can only be minted through the esLBRMinter contract or redeemed for LBR by destruction.
 * - The maximum amount that can be minted through the esLBRMinter contract is 55 million.
 * - esLBR can be used for community governance voting.
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";


/**
 * @title StETH token wrapper with static balances.
 * @dev It's an ERC20 token that represents the account's share of the total
 * supply of stETH tokens. WstETH token's balance only changes on transfers,
 * unlike StETH that is also changed when oracles report staking rewards and
 * penalties. It's a "power user" token for DeFi protocols which don't
 * support rebasable tokens.
 *
 * The contract is also a trustless wrapper that accepts stETH tokens and mints
 * wstETH in return. Then the user unwraps, the contract burns user's wstETH
 * and sends user locked stETH in return.
 *
 * The contract provides the staking shortcut: user can send ETH with regular
 * transfer and get wstETH in return. The contract will send ETH to Lido submit
 * method, staking it and wrapping the received stETH.
 *
 */
contract mockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC")
    {
        _mint(msg.sender, 1000000*1e18);
    }

    function claim() external returns (uint256) {
        _mint(msg.sender, 10000*1e18);
        return 10000*1e18;
    }
    
    function decimals() public view override returns (uint8) {
        return 6;
    }
}