// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;
/**
 * @title DividendPool is a derivative version of Synthetix StakingRewards.sol, distributing Protocol revenue to esLBR stakers.
 * Converting esLBR to LBR.
 * Differences from the original contract,
 * - Get `totalStaked` from totalSupply() in contract esLBR.
 * - Get `stakedOf(user)` from balanceOf(user) in contract esLBR.
 * - When an address esLBR balance changes, call the refreshReward method to update rewards to be claimed.
 */
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interfaces/IEUSD.sol";
import "../interfaces/Iconfigurator.sol";
import "../interfaces/IesLBR.sol";

interface IesLBRBoost {
    function getUnlockTime(
        address user
    ) external view returns (uint256 unlockTime);
}

contract DividendPool is Ownable {
    Iconfigurator public immutable configurator;
    IesLBR public esLBR;
    IesLBR public LBR;
    IesLBRBoost public esLBRBoost;

    // Sum of (reward rate * dt * 1e18 / total supply)
    uint public rewardPerTokenStored;
    // User address => rewardPerTokenStored
    mapping(address => uint) public userRewardPerTokenPaid;
    // User address => rewards to be claimed
    mapping(address => uint) public rewards;
    mapping(address => uint) public time2fullRedemption;
    mapping(address => uint) public unstakeRate;
    mapping(address => uint) public lastWithdrawTime;
    uint256 immutable exitCycle = 90 days;
    uint256 public grabableAmount;
    uint256 public grabFeeRatio = 3000;
    event Restake(address indexed user, uint256 amount, uint256 time);
    event StakeLBR(address indexed user, uint256 amount, uint256 time);
    event UnstakeLBR(address indexed user, uint256 amount, uint256 time);
    event WithdrawLBR(address indexed user, uint256 amount, uint256 time);
    event ClaimReward(address indexed user, uint256 amount, uint256 time);

    constructor(address _config) {
        configurator = Iconfigurator(_config);
    }

    function setTokenAddress(
        address _eslbr,
        address _lbr,
        address _boost
    ) external onlyOwner {
        esLBR = IesLBR(_eslbr);
        LBR = IesLBR(_lbr);
        esLBRBoost = IesLBRBoost(_boost);
    }

    function setGrabCost(uint256 _ratio) external onlyOwner {
        require(_ratio <= 8000, "BCE");
        grabFeeRatio = _ratio;
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
     * The current time must be greater than the unlock time retrieved from the boost contract for the user.
     * Effects:
     * Resets the user's vesting data, entering a new vesting period, when converting to LBR.
     */
    function unstake(uint256 amount) external {
        require(
            block.timestamp >= esLBRBoost.getUnlockTime(msg.sender),
            "Your lock-in period has not ended. You can't convert your esLBR now."
        );
        esLBR.burn(msg.sender, amount);
        withdraw(msg.sender);
        uint256 total = amount;
        if (time2fullRedemption[msg.sender] > block.timestamp) {
            total +=
                unstakeRate[msg.sender] *
                (time2fullRedemption[msg.sender] - block.timestamp);
        }
        unstakeRate[msg.sender] = total / exitCycle;
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
        require(
            block.timestamp + exitCycle - 3 days >
                time2fullRedemption[msg.sender],
            ""
        );
        uint256 burnAmount = getReservedLBRForVesting(msg.sender) -
            getPreUnlockableAmount(msg.sender);
        uint256 amount = getPreUnlockableAmount(msg.sender) +
            getClaimAbleLBR(msg.sender);
        if (amount > 0) {
            LBR.mint(msg.sender, amount);
        }
        unstakeRate[msg.sender] = 0;
        time2fullRedemption[msg.sender] = 0;
        grabableAmount += burnAmount;
    }

    /**
     * @dev Purchase the accumulated amount of pre-claimed lost ESLBR in the contract using LBR.
     * @param amount The amount of ESLBR to be purchased.
     * Requirements:
     * The amount must be greater than 0.
     */
    function grabEsLBR(uint256 amount) external {
        require(amount > 0, "QMG");
        grabableAmount -= amount;
        LBR.burn(msg.sender, (amount * grabFeeRatio) / 10000);
        esLBR.mint(msg.sender, amount);
    }

    /**
     * @dev Convert unredeemed and converting ESLBR tokens back to LBR.
     */
    function reStake() external {
        uint256 amount = getReservedLBRForVesting(msg.sender) +
            getClaimAbleLBR(msg.sender);
        esLBR.mint(msg.sender, amount);
        unstakeRate[msg.sender] = 0;
        time2fullRedemption[msg.sender] = 0;
        emit Restake(msg.sender, amount, block.timestamp);
    }

    function getPreUnlockableAmount(
        address user
    ) public view returns (uint256 amount) {
        uint256 a = getReservedLBRForVesting(user);
        if (a == 0) return 0;
        amount =
            (a *
                (75e18 -
                    ((time2fullRedemption[user] - block.timestamp) * 70e18) /
                    (exitCycle / 1 days - 3) /
                    1 days)) /
            100e18;
    }

    function getClaimAbleLBR(
        address user
    ) public view returns (uint256 amount) {
        if (time2fullRedemption[user] > lastWithdrawTime[user]) {
            amount = block.timestamp > time2fullRedemption[user]
                ? unstakeRate[user] *
                    (time2fullRedemption[user] - lastWithdrawTime[user])
                : unstakeRate[user] *
                    (block.timestamp - lastWithdrawTime[user]);
        }
    }

    function getReservedLBRForVesting(
        address user
    ) public view returns (uint256 amount) {
        if (time2fullRedemption[user] > block.timestamp) {
            amount =
                unstakeRate[user] *
                (time2fullRedemption[user] - block.timestamp);
        }
    }

    function earned(address _account) public view returns (uint) {
        return
            ((stakedOf(_account) *
                (rewardPerTokenStored - userRewardPerTokenPaid[_account])) /
                1e18) + rewards[_account];
    }

    function getClaimAbleUSD(
        address user
    ) external view returns (uint256 amount) {
        amount = IEUSD(configurator.getEUSDAddress()).getMintedEUSDByShares(
            earned(user)
        );
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

    function getReward() external updateReward(msg.sender) {
        uint reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            IEUSD EUSD = IEUSD(configurator.getEUSDAddress());
            EUSD.transferShares(msg.sender, reward);
            emit ClaimReward(
                msg.sender,
                EUSD.getMintedEUSDByShares(reward),
                block.timestamp
            );
        }
    }

    /**
     * @dev The amount of EUSD acquiered from the sender is euitably distributed to LBR stakers.
     * Calculate share by amount, and calculate the shares could claim by per unit of staked ETH.
     * Add into rewardPerTokenStored.
     */
    function notifyRewardAmount(uint amount) external {
        require(msg.sender == address(configurator));
        if (totalStaked() == 0) return;
        require(amount > 0, "amount = 0");
        uint256 share = IEUSD(configurator.getEUSDAddress())
            .getSharesByMintedEUSD(amount);
        rewardPerTokenStored =
            rewardPerTokenStored +
            (share * 1e18) /
            totalStaked();
    }
}
