// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;
/**
 * @title ProtocolRewardsPool is a derivative version of Synthetix StakingRewards.sol, distributing Protocol revenue to esLBR stakers.
 * Converting esLBR to LBR.
 * Differences from the original contract,
 * - Get `totalStaked` from totalSupply() in contract esLBR.
 * - Get `stakedOf(user)` from balanceOf(user) in contract esLBR.
 * - When an address esLBR balance changes, call the refreshReward method to update rewards to be claimed.
 */
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interfaces/Iconfigurator.sol";
import "../interfaces/IesLBR.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface IesLBRBoost {
    function userLockStatus(
        address user
    ) external view returns (uint256, uint256, uint256, uint256);
}

contract ProtocolRewardsPool is Ownable {
    using SafeERC20 for ERC20;
    Iconfigurator public immutable configurator;
    IesLBR public esLBR;
    IesLBR public LBR;
    IesLBRBoost public esLBRBoost;
    AggregatorV3Interface internal lbrPriceFeed;
    // Sum of (reward ratio * dt * 1e18 / total supply)
    uint public rewardPerTokenStored;
    // User address => rewardPerTokenStored
    mapping(address => uint) public userRewardPerTokenPaid;
    // User address => rewards to be claimed
    mapping(address => uint) public rewards;
    mapping(address => uint) public time2fullRedemption;
    mapping(address => uint) public unstakeRatio;
    mapping(address => uint) public lastWithdrawTime;
    uint256 immutable exitCycle = 90 days;
    uint256 public grabableAmount;
    uint256 public grabFeeRatio = 3000;
    event Restake(address indexed user, uint256 amount, uint256 time);
    event StakeLBR(address indexed user, uint256 amount, uint256 time);
    event UnstakeLBR(address indexed user, uint256 amount, uint256 time);
    event WithdrawLBR(address indexed user, uint256 amount, uint256 time);
    event ClaimReward(address indexed user, uint256 eUSDAmount, address indexed token, uint256 tokenAmount, uint256 time);
    event GrabEsLBR(address indexed user, uint256 esLBRAmount, uint256 payAmount, bool useEUSD, uint256 time);

    constructor(address _config) {
        configurator = Iconfigurator(_config);
    }

    function setTokenAddress(address _eslbr, address _lbr, address _boost, address _lbrOracle) external onlyOwner {
        esLBR = IesLBR(_eslbr);
        LBR = IesLBR(_lbr);
        esLBRBoost = IesLBRBoost(_boost);
        lbrPriceFeed = AggregatorV3Interface(_lbrOracle);
    }

    function setGrabCost(uint256 _ratio) external onlyOwner {
        require(_ratio <= 8000, "BCE");
        grabFeeRatio = _ratio;
    }

    function setLBROracle(address _lbrOracle) external onlyOwner {
        lbrPriceFeed = AggregatorV3Interface(_lbrOracle);
    }

    // Total staked
    function totalStaked() internal view returns (uint256) {
        return esLBR.totalSupply();
    }

    // User address => esLBR balance
    function stakedOf(address staker) internal view returns (uint256) {
        return esLBR.balanceOf(staker);
    }

    function stake(uint256 amount) external {
        LBR.burn(msg.sender, amount);
        esLBR.mint(msg.sender, amount);
        emit StakeLBR(msg.sender, amount, block.timestamp);
    }

    /**
     * @dev Unlocks esLBR and converts it to LBR.
     * @param amount The amount to convert.
     * Requirements:
     * If the current time is less than the unlock time of the user's lock status in the esLBRBoost contract,
     * the locked portion in the esLBRBoost contract cannot be unlocked.
     * Effects:
     * Resets the user's vesting data, entering a new vesting period, when converting to LBR.
     */
    function unstake(uint256 amount) external {
        (uint256 lockedAmount, uint256 unLockTime,,) = esLBRBoost.userLockStatus(msg.sender);
        if(block.timestamp < unLockTime) {
            require(esLBR.balanceOf(msg.sender) >= lockedAmount + amount, "UCE");
        }
        esLBR.burn(msg.sender, amount);
        withdraw(msg.sender);
        uint256 total = amount;
        if (time2fullRedemption[msg.sender] > block.timestamp) {
            total += unstakeRatio[msg.sender] * (time2fullRedemption[msg.sender] - block.timestamp);
        }
        unstakeRatio[msg.sender] = total / exitCycle;
        time2fullRedemption[msg.sender] = block.timestamp + exitCycle;
        emit UnstakeLBR(msg.sender, amount, block.timestamp);
    }

    function withdraw(address user) public {
        uint256 amount = getClaimAbleLBR(user);
        if (amount > 0) {
            LBR.mint(user, amount);
        }
        lastWithdrawTime[user] = block.timestamp;
        emit WithdrawLBR(user, amount, block.timestamp);
    }

    /**
     * @dev Redeems and converts the ESLBR being claimed in advance,
     * with the lost portion being recorded in the contract and available for others to purchase in LBR at a certain ratio.
     */
    function unlockPrematurely() external {
        require(block.timestamp + exitCycle - 3 days > time2fullRedemption[msg.sender], "ENW");
        uint256 burnAmount = getReservedLBRForVesting(msg.sender) - getPreUnlockableAmount(msg.sender);
        uint256 amount = getPreUnlockableAmount(msg.sender) + getClaimAbleLBR(msg.sender);
        if (amount > 0) {
            LBR.mint(msg.sender, amount);
        }
        unstakeRatio[msg.sender] = 0;
        time2fullRedemption[msg.sender] = 0;
        grabableAmount += burnAmount;
    }

    /**
     * @dev Purchase the accumulated amount of pre-claimed lost ESLBR in the contract using LBR or eUSD.
     * @param amount The amount of ESLBR to be purchased.
     * Requirements:
     * The amount must be greater than 1e17.
     */
    function grabEsLBR(uint256 amount, bool useEUSD) external {
        require(amount > 1e17, "QMG");
        grabableAmount -= amount;
        uint256 payAmount = amount * grabFeeRatio / 10_000;
        if(useEUSD) {
            (, int lbrPrice, , , ) = lbrPriceFeed.latestRoundData();
            payAmount = payAmount * uint256(lbrPrice) / 1e8;
            bool success = ERC20(configurator.getEUSDAddress()).transferFrom(msg.sender, address(owner()), payAmount);
            require(success, "TF");
        } else {
            LBR.burn(msg.sender, payAmount);
        }
        esLBR.mint(msg.sender, amount);
        emit GrabEsLBR(msg.sender, amount, payAmount, useEUSD, block.timestamp);
    }

    /**
     * @dev Convert unredeemed and converting ESLBR tokens back to LBR.
     */
    function reStake() external {
        uint256 amount = getReservedLBRForVesting(msg.sender) + getClaimAbleLBR(msg.sender);
        esLBR.mint(msg.sender, amount);
        unstakeRatio[msg.sender] = 0;
        time2fullRedemption[msg.sender] = 0;
        emit Restake(msg.sender, amount, block.timestamp);
    }

    function getPreUnlockableAmount(address user) public view returns (uint256 amount) {
        uint256 a = getReservedLBRForVesting(user);
        if (a == 0) return 0;
        amount = (a * (75e18 - ((time2fullRedemption[user] - block.timestamp) * 70e18) / (exitCycle / 1 days - 3) / 1 days)) / 100e18;
    }

    function getClaimAbleLBR(address user) public view returns (uint256 amount) {
        if (time2fullRedemption[user] > lastWithdrawTime[user]) {
            amount = block.timestamp > time2fullRedemption[user] ? unstakeRatio[user] * (time2fullRedemption[user] - lastWithdrawTime[user]) : unstakeRatio[user] * (block.timestamp - lastWithdrawTime[user]);
        }
    }

    function getReservedLBRForVesting(address user) public view returns (uint256 amount) {
        if (time2fullRedemption[user] > block.timestamp) {
            amount = unstakeRatio[user] * (time2fullRedemption[user] - block.timestamp);
        }
    }

    function earned(address _account) public view returns (uint) {
        return ((stakedOf(_account) * (rewardPerTokenStored - userRewardPerTokenPaid[_account])) / 1e18) + rewards[_account];
    }

    /**
     * @dev Call this function when deposit or withdraw ETH on Lybra and update the status of corresponding user.
     */
    modifier updateReward(address account) {
        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
        _;
    }

    function refreshReward(address _account) external updateReward(_account) {}

    /**
     * @notice When claiming protocol rewards earnings, 
     * peUSD will be prioritized for distribution if there is a sufficient amount of peUSD in the Protocol Rewards Pool. 
     * If the peUSD balance is insufficient, earnings will be distributed in the order of other stablecoins such as USDC.
     */
    function getReward() external updateReward(msg.sender) {
        uint reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            ERC20 peUSD = ERC20(configurator.peUSD());
            uint256 balance = peUSD.balanceOf(address(this));
            uint256 peUSDAmount = balance >= reward ? reward : balance;
            peUSD.transfer(msg.sender, peUSDAmount);
            if(reward > peUSDAmount) {
                ERC20 token = ERC20(configurator.stableToken());
                uint256 tokenAmount = (reward - peUSDAmount) * token.decimals() / 1e18;
                token.safeTransfer(msg.sender, tokenAmount);
                emit ClaimReward(msg.sender, peUSDAmount, address(token), reward - peUSDAmount, block.timestamp);
            } else {
                emit ClaimReward(msg.sender, peUSDAmount, address(0), 0, block.timestamp);
            }
           
        }
    }

    /**
     * @notice Notifies the protocol rewards pool about the amount of rewards to be distributed and the token type.
     * @param amount The amount of rewards to be distributed.
     * @param tokenType The type of token (0 for peUSD, 1 for other stablecoins).
     * Requirements:
     * - The caller must be the configurator contract.
     * - There must be staked tokens in the protocol rewards pool.
     * - The amount must not be zero.
     * @dev When receiving stablecoin tokens other than eUSD, the decimals of the token are converted to 18 for consistent calculations.
     */
    function notifyRewardAmount(uint amount, uint tokenType) external {
        require(msg.sender == address(configurator), "NA");
        if (totalStaked() == 0) return;
        require(amount != 0, "amount = 0");
        if(tokenType == 1) {
            ERC20 token = ERC20(configurator.stableToken());
            rewardPerTokenStored = rewardPerTokenStored + (amount * 1e36 / (10 ** token.decimals())) / totalStaked();
        } else {
            rewardPerTokenStored = rewardPerTokenStored + (amount * 1e18) / totalStaked();
        }
    }
}
