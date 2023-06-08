// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;
/**
 * @title tokenMiner is a stripped down version of Synthetix StakingRewards.sol, to reward esLBR to EUSD minters.
 * Differences from the original contract,
 * - Get `totalStaked` from totalSupply() in contract EUSD.
 * - Get `stakedOf(user)` from getBorrowedOf(user) in contract EUSD.
 * - When an address borrowed EUSD amount changes, call the refreshReward method to update rewards to be claimed.
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IesLBR.sol";
import "../interfaces/IEUSD.sol";
import "../interfaces/ILybra.sol";
import "../interfaces/Iconfigurator.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface IesLBRBoost {
    function getUserBoost(
        address user,
        uint256 userUpdatedAt,
        uint256 finishAt
    ) external view returns (uint256);
}

contract EUSDMiningIncentives is Ownable {
    Iconfigurator public immutable configurator;
    IesLBRBoost public esLBRBoost;
    IEUSD public immutable EUSD;
    address public esLBR;
    address public LBR;
    address[] public pools;

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
    uint256 public extraRate = 50 * 1e18;
    uint256 public biddingFeeRatio = 3000;
    address public ethlbrStakePool;
    address public ethlbrLpToken;
    AggregatorV3Interface internal priceFeed =
        AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

    event ClaimReward(address indexed user, uint256 amount, uint256 time);
    event BuyReward(
        address indexed user,
        address indexed Victim,
        uint256 buyAmount,
        uint256 biddingFee,
        uint256 time
    );
    event NotifyRewardChanged(uint256 addAmount, uint256 time);

    constructor(address _config, address _boost) {
        configurator = Iconfigurator(_config);
        esLBRBoost = IesLBRBoost(_boost);
        EUSD = IEUSD(configurator.getEUSDAddress());
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

    function setEsLBR(address _eslbr) external onlyOwner {
        esLBR = _eslbr;
    }

    function setLBR(address _lbr) external onlyOwner {
        LBR = _lbr;
    }

    function setPools(address[] memory _pools) external onlyOwner {
        for (uint i = 0; i < _pools.length; i++) {
            require(configurator.mintVault(_pools[i]), "");
        }
        pools = _pools;
    }

    function setBiddingCost(uint256 _biddingRatio) external onlyOwner {
        require(_biddingRatio <= 8000, "BCE");
        biddingFeeRatio = _biddingRatio;
    }

    function setExtraRate(uint256 rate) external onlyOwner {
        extraRate = rate;
    }

    function setBoost(address _boost) external onlyOwner {
        esLBRBoost = IesLBRBoost(_boost);
    }

    function setRewardsDuration(uint256 _duration) external onlyOwner {
        require(finishAt < block.timestamp, "reward duration not finished");
        duration = _duration;
    }

    function setEthlbrStakeInfo(address _pool, address _lp) external onlyOwner {
        ethlbrStakePool = _pool;
        ethlbrLpToken = _lp;
    }

    function totalStaked() internal view returns (uint256) {
        return EUSD.totalSupply();
    }

    function stakedOf(address user) public view returns (uint256) {
        uint256 amount;
        for (uint i = 0; i < pools.length; i++) {
            ILybra pool = ILybra(pools[i]);
            uint borrowed = pool.getBorrowedOf(user);
            if (pool.getBorrowType() == 1) {
                borrowed = EUSD.getMintedEUSDByShares(borrowed);
            }
            amount += borrowed;
        }
        return amount;
    }

    function stakedLBRLpValue(address user) public view returns (uint256) {
        uint256 totalLp = IEUSD(ethlbrLpToken).totalSupply();
        uint256 lpInethlbrStakePool = IEUSD(ethlbrLpToken).balanceOf(
            ethlbrStakePool
        );
        (, int price, , , ) = priceFeed.latestRoundData();
        uint256 lbrInLp = (IEUSD(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)
            .balanceOf(ethlbrLpToken) * uint(price)) / 1e8;
        uint256 userStaked = IEUSD(ethlbrStakePool).balanceOf(user);
        return
            (userStaked * lbrInLp * lpInethlbrStakePool * 2) /
            totalLp /
            IEUSD(ethlbrStakePool).totalSupply();
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
    function refreshReward(address _account) external updateReward(_account) {}

    function getBoost(address _account) public view returns (uint256) {
        uint256 redemptionBoost;
        if (configurator.isRedemptionProvider(_account)) {
            redemptionBoost = extraRate;
        }
        return
            100 *
            1e18 +
            redemptionBoost +
            esLBRBoost.getUserBoost(
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

    function buyAbleByOther(address user) public view returns (bool) {
        return (stakedLBRLpValue(user) * 10000) / stakedOf(user) < 500;
    }

    function getReward() external updateReward(msg.sender) {
        require(
            !buyAbleByOther(msg.sender),
            "Insufficient DLP, unable to claim rewards"
        );
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            IesLBR(esLBR).mint(msg.sender, reward);
            emit ClaimReward(msg.sender, reward, block.timestamp);
        }
    }

    function getOtherReward(address user) external updateReward(user) {
        require(
            buyAbleByOther(user),
            "The rewards of the user cannot be bought out"
        );
        uint256 reward = rewards[user];
        if (reward > 0) {
            rewards[user] = 0;
            uint256 biddingFee = (reward * biddingFeeRatio) / 10000;
            IesLBR(LBR).burn(msg.sender, biddingFee);
            IesLBR(esLBR).mint(msg.sender, reward);

            emit BuyReward(
                msg.sender,
                user,
                reward,
                biddingFee,
                block.timestamp
            );
        }
    }

    function notifyRewardAmount(
        uint256 amount
    ) external onlyOwner updateReward(address(0)) {
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
        emit NotifyRewardChanged(amount, block.timestamp);
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x <= y ? x : y;
    }
}
