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
    uint256 public rewardRatio;
    // Sum of (reward ratio * dt * 1e18 / total supply)
    uint256 public rewardPerTokenStored;
    // User address => rewardPerTokenStored
    mapping(address => uint256) public userRewardPerTokenPaid;
    // User address => rewards to be claimed
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userUpdatedAt;
    uint256 public extraRatio = 50 * 1e18;
    uint256 public peUSDExtraRatio = 10 * 1e18;
    uint256 public biddingFeeRatio = 3000;
    address public ethlbrStakePool;
    address public ethlbrLpToken;
    AggregatorV3Interface internal etherPriceFeed;
    AggregatorV3Interface internal lbrPriceFeed;
    bool public isEUSDBuyoutAllowed = true;

    event ClaimReward(address indexed user, uint256 amount, uint256 time);
    event ClaimedOtherEarnings(address indexed user, address indexed Victim, uint256 buyAmount, uint256 biddingFee, bool useEUSD, uint256 time);
    event NotifyRewardChanged(uint256 addAmount, uint256 time);

    //etherOracle = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
    constructor(address _config, address _boost, address _etherOracle, address _lbrOracle) {
        configurator = Iconfigurator(_config);
        esLBRBoost = IesLBRBoost(_boost);
        EUSD = IEUSD(configurator.getEUSDAddress());
        etherPriceFeed = AggregatorV3Interface(_etherOracle);
        lbrPriceFeed = AggregatorV3Interface(_lbrOracle);
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

    function setToken(address _lbr, address _eslbr) external onlyOwner {
        LBR = _lbr;
        esLBR = _eslbr;
    }

    function setLBROracle(address _lbrOracle) external onlyOwner {
        lbrPriceFeed = AggregatorV3Interface(_lbrOracle);
    }

    function setPools(address[] memory _pools) external onlyOwner {
        for (uint i = 0; i < _pools.length; i++) {
            require(configurator.mintVault(_pools[i]), "NOT_VAULT");
        }
        pools = _pools;
    }

    function setBiddingCost(uint256 _biddingRatio) external onlyOwner {
        require(_biddingRatio <= 8000, "BCE");
        biddingFeeRatio = _biddingRatio;
    }

    function setExtraRatio(uint256 ratio) external onlyOwner {
        require(ratio <= 1e20, "BCE");
        extraRatio = ratio;
    }

    function setPeUSDExtraRatio(uint256 ratio) external onlyOwner {
        require(ratio <= 1e20, "BCE");
        peUSDExtraRatio = ratio;
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
    function setEUSDBuyoutAllowed(bool _bool) external onlyOwner {
        isEUSDBuyoutAllowed = _bool;
    }

    function totalStaked() internal view returns (uint256) {
        return EUSD.totalSupply();
    }

    function stakedOf(address user) public view returns (uint256) {
        uint256 amount;
        for (uint i = 0; i < pools.length; i++) {
            ILybra pool = ILybra(pools[i]);
            uint borrowed = pool.getBorrowedOf(user);
            if (pool.getVaultType() == 1) {
                borrowed = borrowed * (1e20 + peUSDExtraRatio) / 1e20;
            }
            amount += borrowed;
        }
        return amount;
    }

    function stakedLBRLpValue(address user) public view returns (uint256) {
        uint256 totalLp = IEUSD(ethlbrLpToken).totalSupply();
        (, int etherPrice, , , ) = etherPriceFeed.latestRoundData();
        (, int lbrPrice, , , ) = lbrPriceFeed.latestRoundData();
        uint256 etherInLp = (IEUSD(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2).balanceOf(ethlbrLpToken) * uint(etherPrice)) / 1e8;
        uint256 lbrInLp = (IEUSD(LBR).balanceOf(ethlbrLpToken) * uint(lbrPrice)) / 1e8;
        uint256 userStaked = IEUSD(ethlbrStakePool).balanceOf(user);
        return (userStaked * (lbrInLp + etherInLp)) / totalLp;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return _min(finishAt, block.timestamp);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked() == 0) {
            return rewardPerTokenStored;
        }

        return rewardPerTokenStored + (rewardRatio * (lastTimeRewardApplicable() - updatedAt) * 1e18) / totalStaked();
    }

    /**
     * @notice Update user's claimable reward data and record the timestamp.
     */
    function refreshReward(address _account) external updateReward(_account) {}

    function getBoost(address _account) public view returns (uint256) {
        uint256 redemptionBoost;
        if (configurator.isRedemptionProvider(_account)) {
            redemptionBoost = extraRatio;
        }
        return 100 * 1e18 + redemptionBoost + esLBRBoost.getUserBoost(_account, userUpdatedAt[_account], finishAt);
    }

    function earned(address _account) public view returns (uint256) {
        return ((stakedOf(_account) * getBoost(_account) * (rewardPerToken() - userRewardPerTokenPaid[_account])) / 1e38) + rewards[_account];
    }

    function isOtherEarningsClaimable(address user) public view returns (bool) {
        return (stakedLBRLpValue(user) * 10000) / stakedOf(user) < 500;
    }

    function getReward() external updateReward(msg.sender) {
        require(!isOtherEarningsClaimable(msg.sender), "Insufficient DLP, unable to claim rewards");
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            IesLBR(esLBR).mint(msg.sender, reward);
            emit ClaimReward(msg.sender, reward, block.timestamp);
        }
    }

    function purchaseOtherEarnings(address user, bool useEUSD) external updateReward(user) {
        require(isOtherEarningsClaimable(user), "The rewards of the user cannot be bought out");
        if(useEUSD) {
            require(isEUSDBuyoutAllowed, "The purchase using EUSD is not permitted.");
        }
        uint256 reward = rewards[user];
        if (reward > 0) {
            rewards[user] = 0;
            uint256 biddingFee = (reward * biddingFeeRatio) / 10000;
            if(useEUSD) {
                (, int lbrPrice, , , ) = lbrPriceFeed.latestRoundData();
                biddingFee = biddingFee * uint256(lbrPrice) / 1e8;
                bool success = EUSD.transferFrom(msg.sender, address(configurator), biddingFee);
                require(success, "TF");
                try configurator.distributeRewards() {} catch {}
            } else {
                IesLBR(LBR).burn(msg.sender, biddingFee);
            }
            IesLBR(esLBR).mint(msg.sender, reward);

            emit ClaimedOtherEarnings(msg.sender, user, reward, biddingFee, useEUSD, block.timestamp);
        }
    }

    function notifyRewardAmount(
        uint256 amount
    ) external onlyOwner updateReward(address(0)) {
        require(amount > 0, "amount = 0");
        if (block.timestamp >= finishAt) {
            rewardRatio = amount / duration;
        } else {
            uint256 remainingRewards = (finishAt - block.timestamp) * rewardRatio;
            rewardRatio = (amount + remainingRewards) / duration;
        }

        require(rewardRatio > 0, "reward ratio = 0");

        finishAt = block.timestamp + duration;
        updatedAt = block.timestamp;
        emit NotifyRewardChanged(amount, block.timestamp);
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x <= y ? x : y;
    }
}
