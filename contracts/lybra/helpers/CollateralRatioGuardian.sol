// SPDX-License-Identifier: GPL-3.0
/////////////////////////////////// The contract currently lacks generality and requires modification.

pragma solidity 0.8.17;

import "../interfaces/ILybra.sol";
import "../interfaces/Iconfigurator.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CollateralRatioGuardian is Ownable {
    Iconfigurator public immutable configurator;
    ILybra public immutable EUSD;
    AggregatorV3Interface internal priceFeed =
        AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

    mapping (address => mapping(address => RepaymentSetting)) public userRepaymentSettings;
    uint256 public fee = 200 * 1e18;

    struct RepaymentSetting {
        uint256 triggerCollateralRatio;
        uint256 expectedCollateralRatio;
        bool active;
    }

    event UserActivatedAutoRepayment(address indexed user, address pool, uint256 triggerCollateralRatio, uint256 expectedCollateralRatio);
    event UserDeactivatedAutoRepayment(address indexed user, address pool);
    event ServiceFeeChanged(uint256 newFee, uint256 time);
    event ExecuteAutoRepayment(address indexed user, address keeper, uint256 repayAmount, uint256 fee, uint256 time);

    constructor(address _lybra, address _config) {
        EUSD = ILybra(_lybra);
        configurator = Iconfigurator(_config);
    }

    /**
    * @notice Allows the admin to modify the service fee, with a maximum of 500 eUSD.
    * @dev Only the admin is allowed to call this function to modify the service fee.
    * @param _fee The new service fee amount. Must be between 100 and 500 eUSD.
    */
    function setFee(uint256 _fee) external onlyOwner {
        require(_fee <= 500 * 1e18 && _fee >= 100 * 1e18, "Fee must be between 100 and 500 eUSD");
        fee = _fee;
        emit ServiceFeeChanged(_fee, block.timestamp);
    }

    /**
    * @notice Enables the user to activate the automatic repayment feature.
    * @dev The user can enable the automatic repayment feature by calling this function.
    * @param expectedCollateralRatio The expected collateralization rate. Must be greater than the trigger collateralization rate and the safe collateralization rate specified by the Lybra contract.
    * @param triggerCollateralRatio The trigger collateralization rate. Must be greater than the bad collateralization rate specified by the Lybra contract.
    */
    function enableAutoRepayment(address pool, uint256 triggerCollateralRatio, uint256 expectedCollateralRatio) external {
        require(expectedCollateralRatio > triggerCollateralRatio, "The expectedCollateralRatio needs to be higher than the triggerCollateralRatio.");
        require(triggerCollateralRatio > configurator.badCollateralRate(), "The triggerCollateralRatio needs to be higher than EUSD.badCollateralRatio.");
        require(expectedCollateralRatio >= configurator.getSafeCollateralRate(pool), "The expectedCollateralRatio needs to be greater than or equal to EUSD.safeCollateralRatio");
        userRepaymentSettings[msg.sender][pool] = RepaymentSetting(triggerCollateralRatio, expectedCollateralRatio, true);
        emit UserActivatedAutoRepayment(msg.sender, pool, triggerCollateralRatio, expectedCollateralRatio);
    }

    /**
    * @notice Allows the user to disable the automatic repayment feature.
    */
    function disableAutoRepayment(address pool) external {
        require(userRepaymentSettings[msg.sender][pool].active == true, "The automatic repayment is not enabled.");
         userRepaymentSettings[msg.sender][pool].active = false;
         emit UserDeactivatedAutoRepayment(msg.sender, pool);
    }

    /**
    * @notice Retrieves the real-time price of ETH using Chainlink.
    * @return The real-time price of ETH.convert the return value from Chainlink to 18 decimals.
    */
    function getEtherPrice() public view returns (uint256) {
        // prettier-ignore
        (
            /* uint80 roundID */,
            int price,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = priceFeed.latestRoundData();
        require(price > 0, "The ChainLink return value must be greater than 0.");
        return uint256(price * 1e10);
    }

    
    /**
    * @dev Allows any third-party keeper to trigger automatic repayment for a user.
    * Requirements:
    * `user` must have enabled the automatic repayment feature.
    * Current collateral ratio of the user must be less than or equal to userSetting.triggerCollateralRatio.
    * `user` must have authorized this contract to spend eUSD in an amount greater than the repayment amount + fee.
    */
    // function execute(address user, address pool) external {
    //     RepaymentSetting memory userSetting = userRepaymentSettings[user][pool];
    //     require(userSetting.active == true, "The user has not enabled the automatic repayment");
    //     uint256 userCollateralRatio = getCollateralRatio(user);
    //     require(userCollateralRatio <= userSetting.triggerCollateralRatio, "The user's collateralRate is not below the trigger collateralRate");

    //     uint256 targetDebt = (EUSD.depositedAsset(user) * getEtherPrice()) * 100 / userSetting.expectedCollateralRatio;
    //     uint256 repayAmount = EUSD.getBorrowedOf(user) - targetDebt ;
    //     EUSD.transferFrom(user, address(this), repayAmount + fee);
    //     EUSD.burn(user, repayAmount);
    //     uint256 balance = EUSD.balanceOf(address(this)) < fee ? EUSD.balanceOf(address(this)):fee;
    //     EUSD.transfer(msg.sender, balance);
    //     emit ExecuteAutoRepayment(user, msg.sender, repayAmount, balance, block.timestamp);
    // }

    // /**
    // * @dev Returns whether it is possible to invoke the automatic repayment function on behalf of `user`.
    // * @return True if it is possible to invoke the automatic repayment function on behalf of `user`, otherwise false.
    // */
    // function checkExecutionFeasibility(address user) external view returns(bool) {
    //     RepaymentSetting memory userSetting = userRepaymentSettings[user];
    //     if(userSetting.active != true) return false;
    //     uint256 userCollateralRatio = getCollateralRatio(user);
    //     if(userCollateralRatio > userSetting.triggerCollateralRatio) return false;

    //     uint256 targetDebt = (EUSD.depositedAsset(user) * getEtherPrice()) * 100 / userSetting.expectedCollateralRatio;
    //     uint256 totalAmount = EUSD.getBorrowedOf(user) - targetDebt + fee;
    //     if(EUSD.allowance(user, address(this)) < totalAmount || EUSD.balanceOf(user) < totalAmount) return false;
    //     return true;
    // }

    /**
    * @dev Retrieves the current collateral ratio of `user`.
    */
    function getCollateralRatio(address user) public view returns (uint256) {
        if (EUSD.getBorrowedOf(user) == 0) return 1e22;
        return
            (EUSD.depositedAsset(user) * getEtherPrice()) * 100 /
            EUSD.getBorrowedOf(user);
    }
    
}
