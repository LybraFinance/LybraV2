// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;
/**
 * @title esLBR is an ERC20-compliant token, but cannot be transferred and can only be minted through the esLBRMinter contract or redeemed for LBR by destruction.
 * - The maximum amount that can be minted through the esLBRMinter contract is 55 million.
 * - esLBR can be used for community governance voting.
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@layerzerolabs/solidity-examples/contracts/lzApp/NonblockingLzApp.sol";

interface IesLBR {
    function mint(address user, uint256 amount) external returns(bool);
    function burn(address user, uint256 amount) external returns(bool);
}
contract LBRMinerFromL2 is NonblockingLzApp {
    IesLBR immutable esLBR;
    event ClaimReward(address indexed user, uint256 amount, uint256 time);

    constructor(address _eslbr, address _lzEndpoint) NonblockingLzApp(_lzEndpoint) {
        esLBR = IesLBR(_eslbr);
    }


    function _nonblockingLzReceive(uint16, bytes memory, uint64, bytes memory _payload) internal override {
        (address to, uint256 amount) = abi.decode(_payload, (address, uint256));
        esLBR.mint(to, amount);
        emit ClaimReward(to, amount, block.timestamp);
    }
}