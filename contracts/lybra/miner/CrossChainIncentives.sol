// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;
/**
 * @title esLBRMiner is a stripped down version of Synthetix StakingRewards.sol, to reward esLBR to EUSD minters.
 * Differences from the original contract,
 * - Get `totalStaked` from totalSupply() in contract EUSD.
 * - Get `stakedOf(user)` from getBorrowedOf(user) in contract EUSD.
 * - When an address borrowed EUSD amount changes, call the refreshReward method to update rewards to be claimed.
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IesLBR.sol";
import "../interfaces/Iconfigurator.sol";

interface ICrossChainPool {
    function totalStaked() external view returns(uint256);
    function stakedOf(address user) external view returns(uint256);
}

interface IlybraFund {
    function refreshReward(address user) external;
}

interface IesLBRBoost {
    function getUserBoost(
        address user,
        uint256 userUpdatedAt,
        uint256 finishAt
    ) external view returns (uint256);

    function getUnlockTime(address user)
        external
        view
        returns (uint256 unlockTime);
}

contract CrossChainIncentives is Ownable {
    Iconfigurator public immutable configurator;
    IesLBRBoost public esLBRBoost;
    IlybraFund public lybraFund;
    address public esLBR;

    // Duration of rewards to be paid out (in seconds)
    uint256 public duration = 2_592_000;
    // Timestamp of when the rewards finish
    uint256 public finishAt;
    // Minimum of last updated time and reward finish time
    uint256 public updatedAt;
    // Reward to be paid out per second
    uint256 public rewardRate;
    // Sum of (reward rate * dt * 1e18 / total supply)
    uint256 public rewardPerTokenStored;
    // User address => rewardPerTokenStored
    mapping(address => uint256) public userRewardPerTokenPaid;
    // User address => rewards to be claimed
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userUpdatedAt;

    constructor(
        address _config,
        address _boost
    ) {
        configurator = Iconfigurator(_config);
        esLBRBoost = IesLBRBoost(_boost);
    }

    function setEsLBR(address _eslbr) external onlyOwner {
        esLBR = _eslbr;
    }

    function setBoost(address _boost) external onlyOwner {
        esLBRBoost = IesLBRBoost(_boost);
    }

    function setRewardsDuration(uint256 _duration) external onlyOwner {
        require(finishAt < block.timestamp, "reward duration not finished");
        duration = _duration;
    }

    function totalStaked() internal view returns (uint256) {
        return ICrossChainPool(configurator.crossChainPool()).totalStaked();
    }

    function stakedOf(address user) public view returns (uint256) {
        return ICrossChainPool(configurator.crossChainPool()).stakedOf(user);
    }

    modifier updateReward(address _account) {
        rewardPerTokenStored = rewardPerToken();
        updatedAt = lastTimeRewardApplicable();

        if (_account != address(0)) {
            rewards[_account] = earned(_account);
            userRewardPerTokenPaid[_account] = rewardPerTokenStored;
            userUpdatedAt[_account] = block.timestamp;
        }

        _;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return _min(finishAt, block.timestamp);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked() == 0) {
            return rewardPerTokenStored;
        }

        return
            rewardPerTokenStored +
            (rewardRate * (lastTimeRewardApplicable() - updatedAt) * 1e18) /
            totalStaked();
    }

    /**
     * @notice Update user's claimable reward data and record the timestamp.
     */
    function refreshReward(address _account) external updateReward(_account) {
    }

    function getBoost(address _account) public view returns (uint256) {
        return 100 * 1e18 + esLBRBoost.getUserBoost(
            _account,
            userUpdatedAt[_account],
            finishAt
        );
    }

    function earned(address _account) public view returns (uint256) {
        return
            ((stakedOf(_account) *
                getBoost(_account) *
                (rewardPerToken() - userRewardPerTokenPaid[_account])) / 1e38) +
            rewards[_account];
    }

    function getReward() external updateReward(msg.sender) {
        require(
            block.timestamp >= esLBRBoost.getUnlockTime(msg.sender),
            "Your lock-in period has not ended. You can't claim your esLBR now."
        );
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            lybraFund.refreshReward(msg.sender);
            IesLBR(esLBR).mint(msg.sender, reward);
        }
    }

    function notifyRewardAmount(uint256 amount)
        external
        onlyOwner
        updateReward(address(0))
    {
        require(amount > 0, "amount = 0");
        if (block.timestamp >= finishAt) {
            rewardRate = amount / duration;
        } else {
            uint256 remainingRewards = (finishAt - block.timestamp) *
                rewardRate;
            rewardRate = (amount + remainingRewards) / duration;
        }

        require(rewardRate > 0, "reward rate = 0");

        finishAt = block.timestamp + duration;
        updatedAt = block.timestamp;
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x <= y ? x : y;
    }
}
