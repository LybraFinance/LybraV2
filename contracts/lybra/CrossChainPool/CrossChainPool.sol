// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../interfaces/Iconfigurator.sol";
import "../interfaces/Ilido.sol";
import "../interfaces/IEUSD.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Context.sol";

contract CrossChainPool is Context {
    IERC20 public immutable WeUSD;
    Ilido public immutable stETH;
    Iconfigurator public immutable configurator;
    // Use the ETH/USD oracle provided by Chainlink. 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
    AggregatorV3Interface public priceFeed;

    // Total staked
    uint256 public totalStaked;

    /// ERRORS ///
	/// @notice Thrown when the additional fees are not returned before the end of the transaction
	error FeesNotReturned();

	/// EVENTS ///

	/// @notice Emitted when a flash loan is completed
	/// @param receiver The contract that received the funds
	/// @param amount The amount of tokens that were loaned
	event Flashloaned(FlashBorrower indexed receiver, uint256 amount);
	event ProfitDistributionToEUSD(uint256 payoutEther, uint256 eUSDamount, uint256 time);

    constructor(
        address _weusd,
        address _lido,
        address _chainlinkOracle,
        address _config
    ) {
        WeUSD = IERC20(_weusd);
        stETH = Ilido(_lido);
        priceFeed = AggregatorV3Interface(_chainlinkOracle);
        configurator = Iconfigurator(_config);
    }

    function deposit(uint256 amount) external {
        address spender = _msgSender();
        require(spender == address(WeUSD), "");
        require(totalStaked + amount <= configurator.getWeUSDMaxSupplyOnL2(), "ESL");
        totalStaked += amount;
    }

    // Allows users to withdraw a specified amount of staked tokens
    function withdraw(address user, uint256 amount) external {
        address caller = _msgSender();
        require(caller == address(WeUSD), "");
        require(amount > 0, "amount = 0");
        WeUSD.transfer(user, amount);
        totalStaked -= amount;
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
	}

    function excessIncomeDistribution(uint256 payAmount) external {
        uint256 payoutEther = (payAmount * 1e18) / getEtherPrice();
        require(
            payoutEther <=
                stETH.balanceOf(address(this)) &&
                payoutEther > 0,
            "Only LSD excess income can be exchanged"
        );

        uint256 sharesAmount = IEUSD(configurator.getEUSDAddress()).getSharesByMintedEUSD(
                payAmount
            );
            if (sharesAmount == 0) {
                //EUSD totalSupply is 0: assume that shares correspond to EUSD 1-to-1
                sharesAmount = payAmount;
            }

        IEUSD(configurator.getEUSDAddress()).burnShares(msg.sender, sharesAmount);

        stETH.transfer(msg.sender, payoutEther);

        emit ProfitDistributionToEUSD(payoutEther, payAmount, block.timestamp);
    }

    /// @notice Calculate the fee owed for the loaned tokens
	/// @param amount The amount of tokens you're receiving
	/// @return The amount of tokens you need to pay as a fee
	function getFee(uint256 amount) public view returns (uint256) {
        uint256 fee = configurator.crossChainFlashloanFee();
		if (fee == 0) return 0;
		return (amount * 1e18 / getEtherPrice() * fee) / 10_000;
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
        return uint256(price) * 1e10;
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
