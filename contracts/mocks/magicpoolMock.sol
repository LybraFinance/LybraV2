// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
pragma abicoder v2;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract LybraMagicPoolMock is Ownable {
    ILybra public immutable eUSD;
    ILido public immutable stETH;
    IesLBRMinter public esLBRMinter;
    AggregatorV3Interface internal priceFeed;
    uint public rewardPerTokenStored;
    // User address => rewardPerTokenStored
    mapping(address => uint) public userRewardPerTokenPaid;
    // User address => rewards to be claimed
    mapping(address => uint) public rewards;
    mapping(address => uint) public stakedOf;

    // Total staked
    uint256 public totalStaked;
    uint256 public flashloanFee = 500;

    /// ERRORS ///

	/// @notice Thrown when trying to update token fees or withdraw token balance without being the manager
	error Unauthorized();

	/// @notice Thrown when trying to update token fees to an invalid percentage
	error InvalidPercentage();

	/// @notice Thrown when the additional fees are not returned before the end of the transaction
	error FeesNotReturned();

	/// EVENTS ///

	/// @notice Emitted when the fees for flash loaning a token have been updated
	/// @param fee The new fee for this token as a percentage and multiplied by 100 to avoid decimals (for example, 10% is 10_00)
	event FeeUpdated(uint256 fee);

	/// @notice Emitted when a flash loan is completed
	/// @param receiver The contract that received the funds
	/// @param amount The amount of tokens that were loaned
	event Flashloaned(FlashBorrower indexed receiver, uint256 amount);

    constructor(
        address _eusd,
        address _lido,
        address _esLBRMinter,
        address _ooracle
    ) {
        eUSD = ILybra(_eusd);
        stETH = ILido(_lido);
        esLBRMinter = IesLBRMinter(_esLBRMinter);
        priceFeed =
        AggregatorV3Interface(_ooracle);
    }

    function deposit(address onBehalfOf, uint256 eusdAmount) external updateReward(onBehalfOf) {
        address spender = _msgSender();
        require(spender == address(eUSD), "");
        esLBRMinter.refreshReward(onBehalfOf);
        // eUSD.transferFrom(msg.sender, address(this), eusdAmount);
        uint256 share = eUSD.getSharesByMintedEUSD(eusdAmount);
        stakedOf[onBehalfOf] += share;
        totalStaked += share;
    }

    // Allows users to withdraw a specified amount of staked tokens
    function withdraw(address user, uint256 shareAmount) external updateReward(user) {
        address caller = _msgSender();
        require(caller == address(eUSD), "");
        require(shareAmount > 0, "amount = 0");
        esLBRMinter.refreshReward(user);

        stakedOf[user] -= shareAmount;
        totalStaked -= shareAmount;
        eUSD.transferShares(user, shareAmount);
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
		uint256 share = eUSD.getSharesByMintedEUSD(amount);
        uint256 currentLidoBalance = stETH.balanceOf(address(this));
		emit Flashloaned(receiver, amount);

		eUSD.transferShares(address(receiver), share);
		receiver.onFlashLoan(amount, data);
        eUSD.transferFrom(address(receiver), address(this), eUSD.getMintedEUSDByShares(share));

        uint256 reward = stETH.balanceOf(address(this)) - currentLidoBalance;
        if(reward < getFee(amount)) revert FeesNotReturned();
        notifyRewardAmount(reward);
	}

    /// @notice Calculate the fee owed for the loaned tokens
	/// @param amount The amount of tokens you're receiving
	/// @return The amount of tokens you need to pay as a fee
	function getFee(uint256 amount) public view returns (uint256) {
		if (flashloanFee == 0) return 0;
		return (amount * 1e8 / getEtherPrice() * flashloanFee) / 10_000;
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

	/// @notice Update the fee percentage for eUSD, only available to the manager of the contract
	/// @param fee The fee percentage for this token, multiplied by 100 (for example, 10% is 10_00)
	function setFees(uint256 fee) external  onlyOwner {
		if (fee > 10_000) revert InvalidPercentage();

		emit FeeUpdated(fee);
        flashloanFee = fee;
	}

    function getDepositedEUSD(address user) external view returns(uint256) {
        return eUSD.getMintedEUSDByShares(stakedOf[user]);
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

interface ILybra {
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function sharesOf(address account) external view returns (uint256);

    function totalDepositedEther() external view returns (uint256);

    function safeCollateralRate() external view returns (uint256);

    function redemptionFee() external view returns (uint256);

    function keeperRate() external view returns (uint256);

    function depositedEther(address user) external view returns (uint256);

    function getBorrowedOf(address user) external view returns (uint256);

    function isRedemptionProvider(address user) external view returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);

    function transfer(
        address _recipient,
        uint256 _amount
    ) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function transferShares(
        address _recipient,
        uint256 _sharesAmount
    ) external returns (uint256);

    function getSharesByMintedEUSD(
        uint256 _EUSDAmount
    ) external view returns (uint256);

    function getMintedEUSDByShares(
        uint256 _sharesAmount
    ) external view returns (uint256);
}
