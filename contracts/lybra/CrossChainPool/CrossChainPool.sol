// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../interfaces/Iconfigurator.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Context.sol";

contract CrossChainPool is Context {
    IERC20 public immutable WeUSD;
    ILido public immutable stETH;
    Iconfigurator public immutable configurator;
    // Use the ETH/USD oracle provided by Chainlink. 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
    AggregatorV3Interface internal priceFeed;
    uint public rewardPerTokenStored;
    // User address => rewardPerTokenStored
    mapping(address => uint) public userRewardPerTokenPaid;
    // User address => rewards to be claimed
    mapping(address => uint) public rewards;
    mapping(address => uint) public stakedOf;

    // Total staked
    uint256 public totalStaked;

    /// ERRORS ///

	/// @notice Thrown when trying to update token fees or withdraw token balance without being the manager
	error Unauthorized();

	/// @notice Thrown when the additional fees are not returned before the end of the transaction
	error FeesNotReturned();

	/// EVENTS ///

	/// @notice Emitted when a flash loan is completed
	/// @param receiver The contract that received the funds
	/// @param amount The amount of tokens that were loaned
	event Flashloaned(FlashBorrower indexed receiver, uint256 amount);

    constructor(
        address _weusd,
        address _lido,
        address _chainlinkOracle,
        address _config
    ) {
        WeUSD = IERC20(_weusd);
        stETH = ILido(_lido);
        priceFeed = AggregatorV3Interface(_chainlinkOracle);
        configurator = Iconfigurator(_config);
    }

    function deposit(address onBehalfOf, uint256 amount) external updateReward(onBehalfOf) {
        address spender = _msgSender();
        require(spender == address(WeUSD), "");
        require(totalStaked + amount <= configurator.getWeUSDMaxSupplyOnL2(), "ESL");
        try IesLBRMinter(configurator.crossChainIncentives()).refreshReward(onBehalfOf) {} catch {}

        stakedOf[onBehalfOf] += amount;
        totalStaked += amount;
    }

    // Allows users to withdraw a specified amount of staked tokens
    function withdraw(address user, uint256 amount) external updateReward(user) {
        address caller = _msgSender();
        require(caller == address(WeUSD), "");
        require(amount > 0, "amount = 0");

        try IesLBRMinter(configurator.crossChainIncentives()).refreshReward(user) {} catch {}

        stakedOf[user] -= amount;
        totalStaked -= amount;
        WeUSD.transfer(user, amount);
    }

    /// @notice Request a flash loan
	/// @param receiver The contract that will receive the flash loan
	/// @param amount The amount of tokens you want to borrow
	/// @param data Data to forward to the receiver contract along with your flash loan
	/// @dev Make sure your contract implements the FlashBorrower interface!
	function executeFlashloan(
		FlashBorrower receiver,
		uint256 amount,
		bytes calldata data
	) public payable {
        uint256 currentLidoBalance = stETH.balanceOf(address(this));
		emit Flashloaned(receiver, amount);

		WeUSD.transfer(address(receiver), amount);
		receiver.onFlashLoan(amount, data);
        bool success = WeUSD.transferFrom(address(receiver), address(this), amount);
        require(success, "TF");

        uint256 reward = stETH.balanceOf(address(this)) - currentLidoBalance;
        if(reward < getFee(amount)) revert FeesNotReturned();
        notifyRewardAmount(reward);
	}

    /// @notice Calculate the fee owed for the loaned tokens
	/// @param amount The amount of tokens you're receiving
	/// @return The amount of tokens you need to pay as a fee
	function getFee(uint256 amount) public view returns (uint256) {
        uint256 fee = configurator.crossChainFlashloanFee();
		if (fee == 0) return 0;
		return (amount * 1e8 / getEtherPrice() * fee) / 10_000;
	}

    function getEtherPrice() public view returns (uint256) {
        // prettier-ignore
        (
            /* uint80 roundID */,
            int price,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = priceFeed.latestRoundData();
        return uint256(price);
    }

    function getDepositedWEUSD(address user) external view returns(uint256) {
        return stakedOf[user];
    }

    function getClaimAbleStETH(address user) external view returns (uint256 amount) {
        amount = stETH.getPooledEthByShares(earned(user));
    }

    function earned(address _account) public view returns (uint) {
        return
            ((stakedOf[_account] *
                (rewardPerTokenStored - userRewardPerTokenPaid[_account])) /
                1e18) + rewards[_account];
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

    function getReward(address user) external updateReward(user) {
        uint reward = rewards[user];
        if (reward > 0) {
            rewards[user] = 0;
            stETH.transferShares(user, reward);
        }
    }

    /**
     * @dev The amount of EUSD acquiered from the sender is euitably distributed to LBR stakers.
     * Calculate share by amount, and calculate the shares could claim by per unit of staked ETH.
     * Add into rewardPerTokenStored.
     */
    function notifyRewardAmount(uint amount) internal {
        if (totalStaked == 0) return;
        require(amount > 0, "amount = 0");
        uint256 share = stETH.getSharesByPooledEth(amount);
        rewardPerTokenStored =
            rewardPerTokenStored +
            (share * 1e18) /
            totalStaked;
    }
}

interface ILido {
    function getSharesByPooledEth(uint256 _ethAmount) external view returns (uint256);
    function getPooledEthByShares(uint256 _sharesAmount) external view returns (uint256);
    function transferShares(address _recipient, uint256 _sharesAmount) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface FlashBorrower {
	/// @notice Flash loan callback
	/// @param amount The amount of tokens received
	/// @param data Forwarded data from the flash loan request
	/// @dev Called after receiving the requested flash loan, should return tokens + any fees before the end of the transaction
	function onFlashLoan(
		uint256 amount,
		bytes calldata data
	) external;
}

interface IesLBRMinter {
    function refreshReward(address user) external;
}
