// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../interfaces/IesLBR.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@layerzerolabs/solidity-examples/contracts/lzApp/NonblockingLzApp.sol";

contract StakingRewardsOnArbi is NonblockingLzApp {
    using SafeERC20 for IERC20;
    // Immutable variables for staking and rewards tokens
    IERC20 public immutable stakingToken;

    uint16 public immutable dstChainId;

    // Duration of rewards to be paid out (in seconds)
    uint256 public duration = 2_592_000;
    // Timestamp of when the rewards finish
    uint256 public finishAt;
    // Minimum of last updated time and reward finish time
    uint256 public updatedAt;
    // Reward to be paid out per second
    uint256 public rewardRatio;
    // Sum of (reward ratio * dt * 1e18 / total supply)
    uint256 public rewardPerTokenStored;
    // User address => rewardPerTokenStored
    mapping(address => uint256) public userRewardPerTokenPaid;
    // User address => rewards to be claimed
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userUpdatedAt;

    // Total staked
    uint256 public totalSupply;
    // User address => staked amount
    mapping(address => uint256) public balanceOf;

    ///events
    event StakeToken(address indexed user, uint256 amount, uint256 time);
    event WithdrawToken(address indexed user, uint256 amount, uint256 time);
    event ClaimReward(address indexed user, uint256 amount, uint256 time);
    event NotifyRewardChanged(uint256 addAmount, uint256 time);

    //_dstChainId = 101
    constructor(address _stakingToken, uint16 _dstChainId, address _lzEndpoint) NonblockingLzApp(_lzEndpoint) {
        stakingToken = IERC20(_stakingToken);
        dstChainId = _dstChainId;
    }

    // Update user's claimable reward data and record the timestamp.
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

    // Returns the last time the reward was applicable
    function lastTimeRewardApplicable() public view returns (uint256) {
        return _min(finishAt, block.timestamp);
    }

    // Calculates and returns the reward per token
    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }

        return rewardPerTokenStored + (rewardRatio * (lastTimeRewardApplicable() - updatedAt) * 1e18) / totalSupply;
    }

    // Allows users to stake a specified amount of tokens
    function stake(uint256 _amount) external updateReward(msg.sender) {
        require(_amount != 0, "amount = 0");
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        balanceOf[msg.sender] += _amount;
        totalSupply += _amount;
        emit StakeToken(msg.sender, _amount, block.timestamp);
    }

    // Allows users to withdraw a specified amount of staked tokens
    function withdraw(uint256 _amount) external updateReward(msg.sender) {
        require(_amount != 0, "amount = 0");
        balanceOf[msg.sender] -= _amount;
        totalSupply -= _amount;
        stakingToken.safeTransfer(msg.sender, _amount);
        emit WithdrawToken(msg.sender, _amount, block.timestamp);
    }

    // Calculates and returns the earned rewards for a user
    function earned(address _account) public view returns (uint256) {
        return ((balanceOf[_account] * (rewardPerToken() - userRewardPerTokenPaid[_account])) / 1e18) + rewards[_account];
    }

    // Allows users to claim their earned rewards
    function getReward(address zroPaymentAddress, bytes calldata adapterParams) external updateReward(msg.sender) payable {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            bytes memory payload = abi.encode(msg.sender, reward);
            _lzSend(dstChainId, payload, payable(msg.sender), zroPaymentAddress, adapterParams, msg.value);
            emit ClaimReward(msg.sender, reward, block.timestamp);
        }
    }

    // Allows the owner to set the rewards duration
    function setRewardsDuration(uint256 _duration) external onlyOwner {
        require(finishAt < block.timestamp, "reward duration not finished");
        duration = _duration;
    }

    // Allows the owner to set the mining rewards.
    function notifyRewardAmount(uint256 _amount) external onlyOwner updateReward(address(0)) {
        if (block.timestamp >= finishAt) {
            rewardRatio = _amount / duration;
        } else {
            uint256 remainingRewards = (finishAt - block.timestamp) * rewardRatio;
            rewardRatio = (_amount + remainingRewards) / duration;
        }

        require(rewardRatio != 0, "reward ratio = 0");

        finishAt = block.timestamp + duration;
        updatedAt = block.timestamp;
        emit NotifyRewardChanged(_amount, block.timestamp);
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x <= y ? x : y;
    }

    function _nonblockingLzReceive(uint16, bytes memory _srcAddress, uint64, bytes memory _payload) internal override {
    }
}
