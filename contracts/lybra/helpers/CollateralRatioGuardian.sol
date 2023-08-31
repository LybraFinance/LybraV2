// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.17;

import "../interfaces/Iconfigurator.sol";
import "../interfaces/ILybra.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CollateralRatioGuardian is Ownable {
    Iconfigurator public immutable configurator;
    AggregatorV3Interface immutable priceFeed;

    mapping (address => mapping (address => RepaymentSetting)) public userRepaymentSettings;
    uint256 public fee = 100 * 1e18;

    struct RepaymentSetting {
        uint256 triggerCollateralRatio;
        uint256 expectedCollateralRatio;
        bool active;
    }

    event UserSetAutoRepayment(address indexed user, address indexed vault, uint256 triggerCollateralRatio, uint256 expectedCollateralRatio, bool status);
    event ServiceFeeChanged(uint256 newFee, uint256 time);
    event ExecuteAutoRepayment(address indexed user, address indexed vault, address keeper, uint256 repayAmount, uint256 fee, uint256 time);

    constructor(address _config, address _priceFeed) {
        configurator = Iconfigurator(_config);
        priceFeed = AggregatorV3Interface(_priceFeed);
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
     * @dev Sets the auto repayment settings for each of the user's vaults.
     * @param vaults The array of vault addresses for which to set the repayment settings.
     * @param settings The array of repayment settings corresponding to each vault.
     */
    function setAutoRepayment(address[] memory vaults, RepaymentSetting[] memory settings) external {
        require(vaults.length == settings.length, "ALI");
        for(uint i; i < vaults.length;i++) {
            require(settings[i].expectedCollateralRatio > settings[i].triggerCollateralRatio, "The expectedCollateralRatio needs to be higher than the triggerCollateralRatio.");
            require(settings[i].triggerCollateralRatio > configurator.getBadCollateralRatio(vaults[i]), "The triggerCollateralRatio needs to be higher than lybra.badCollateralRatio.");
            require(settings[i].expectedCollateralRatio >= configurator.getSafeCollateralRatio(vaults[i]), "The expectedCollateralRatio needs to be greater than or equal to lybra.safeCollateralRatio");
            userRepaymentSettings[msg.sender][vaults[i]] = settings[i];
            emit UserSetAutoRepayment(msg.sender, vaults[i], settings[i].triggerCollateralRatio, settings[i].expectedCollateralRatio, settings[i].active);
        }
    }

    /**
    * @dev Allows any third-party keeper to trigger automatic repayment for a user.
    * Requirements:
    * `user` must have enabled the automatic repayment feature.
    * Current collateral ratio of the user must be less than or equal to userSetting.triggerCollateralRatio.
    * `user` must have authorized this contract to spend eUSD in an amount greater than the repayment amount + fee.
    */
    function execute(address user, address vault) external {
        RepaymentSetting memory userSetting = userRepaymentSettings[user][vault];
        require(userSetting.active == true, "The user has not enabled the automatic repayment");
        uint256 userCollateralRatio = getCollateralRatio(user, vault);
        require(userCollateralRatio <= userSetting.triggerCollateralRatio, "The user's collateralRate is not below the trigger collateralRate");

        ILybra lybraPool = ILybra(vault);
        uint256 targetDebt = (lybraPool.depositedAsset(user) * getAssetPrice(vault)) * 100 / userSetting.expectedCollateralRatio;
        uint256 repayAmount = lybraPool.getBorrowedOf(user) - targetDebt ;
        IERC20 token = lybraPool.getVaultType() == 0 ? IERC20(configurator.getEUSDAddress()) : IERC20(configurator.peUSD());
        token.transferFrom(user, address(this), repayAmount + fee);
        lybraPool.burn(user, repayAmount);
        uint256 balance = token.balanceOf(address(this)) < fee ? token.balanceOf(address(this)) : fee;
        token.transfer(msg.sender, balance);
        emit ExecuteAutoRepayment(user, vault, msg.sender, repayAmount, balance, block.timestamp);
    }

    /**
    * @dev Returns whether it is possible to invoke the automatic repayment function on behalf of `user`.
    * @return True if it is possible to invoke the automatic repayment function on behalf of `user`, otherwise false.
    */
    function checkExecutionFeasibility(address user, address vault) external view returns(bool) {
        RepaymentSetting memory userSetting = userRepaymentSettings[user][vault];
        if(userSetting.active != true) return false;
        uint256 userCollateralRatio = getCollateralRatio(user, vault);
        if(userCollateralRatio > userSetting.triggerCollateralRatio) return false;

        ILybra lybraPool = ILybra(vault);
        uint256 targetDebt = (lybraPool.depositedAsset(user) * getAssetPrice(vault)) * 100 / userSetting.expectedCollateralRatio;
        uint256 totalAmount = lybraPool.getBorrowedOf(user) - targetDebt + fee;
        IERC20 token = lybraPool.getVaultType() == 0 ? IERC20(configurator.getEUSDAddress()) : IERC20(configurator.peUSD());
        if(token.allowance(user, address(this)) < totalAmount || token.balanceOf(user) < totalAmount) return false;
        return true;
    }

    /**
    * @dev Retrieves the current collateral ratio of `user`.
    */
    function getCollateralRatio(address user, address vault) public view returns (uint256) {
        ILybra lybraPool = ILybra(vault);
        if (lybraPool.getBorrowedOf(user) == 0) return 1e69;
        return
            lybraPool.depositedAsset(user) * getAssetPrice(vault) * 100 /
            lybraPool.getBorrowedOf(user);
    }

    function getAssetPrice(address vault) public view returns (uint256) {
        (,int price, , , ) = priceFeed.latestRoundData();
        return ILybra(vault).getAsset2EtherExchangeRate() * uint(price) / 1e8;
    }
    
}