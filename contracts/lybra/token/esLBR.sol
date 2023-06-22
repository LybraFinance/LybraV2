// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;
/**
 * @title esLBR is an ERC20-compliant token, but cannot be transferred and can only be minted through the esLBRMinter contract or redeemed for LBR by destruction.
 * - The maximum amount that can be minted through the esLBRMinter contract is 55 million.
 * - esLBR can be used for community governance voting.
 */

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "../interfaces/Iconfigurator.sol";

interface IdividendPool {
    function refreshReward(address user) external;
}

contract esLBR is ERC20Votes {
    Iconfigurator public immutable configurator;

    uint256 maxSupply = 100_000_000 * 1e18;

    constructor(address _config) ERC20Permit("esLBR") ERC20("esLBR", "esLBR") {
        configurator = Iconfigurator(_config);
    }

    function _transfer(address, address, uint256) internal virtual override {
        revert("not authorized");
    }

    function mint(address user, uint256 amount) external returns (bool) {
        require(configurator.tokenMiner(msg.sender), "not authorized");
        require(totalSupply() + amount <= maxSupply, "exceeding the maximum supply quantity.");
        try IdividendPool(configurator.getProtocolRewardsPool()).refreshReward(user) {} catch {}
        _mint(user, amount);
        return true;
    }

    function burn(address user, uint256 amount) external returns (bool) {
        require(configurator.tokenMiner(msg.sender), "not authorized");
        try IdividendPool(configurator.getProtocolRewardsPool()).refreshReward(user) {} catch {}
        _burn(user, amount);
        return true;
    }
}
