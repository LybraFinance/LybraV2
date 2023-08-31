// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract V1eUSDRewards is Ownable {
    address public immutable eUSD;



    constructor(address _eusd) {
        eUSD = _eusd;
    }

    function notifyRewardAmount(uint256 amount) external {

    }

    function setToken(address to, uint256 amount) external onlyOwner {
        IERC20(eUSD).transfer(to, amount);
    }



}
