// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;

import "../interfaces/ILybra.sol";
import "../interfaces/IEUSD.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IStakingRewards {
    function rewardRate() external view returns (uint256);
}

contract LybraHelper is Ownable {
    address[] pools;
    address public lido;
    ILybra stETHPool;
    IEUSD EUSD;
    AggregatorV3Interface internal priceFeed =
        AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

    constructor(address _lido,address _eusd, address _stETHPool) {
        lido = _lido;
        stETHPool = ILybra(_stETHPool);
        EUSD = IEUSD(_eusd);
    }

    function setPool(address[] memory _pools) external onlyOwner {
        pools = _pools;
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

    function getTotalStakedOf(address user) external view returns (uint256) {
        uint256 amount;
        for(uint i=0;i<pools.length;i++) {
            ILybra pool = ILybra(pools[i]);
            uint borrowed = pool.getBorrowedOf(user);
            if(pool.getBorrowType() == 1) {
                borrowed = EUSD.getMintedEUSDByShares(borrowed);
            }
            amount += borrowed;
        }
        return amount;
    }

    function getCollateralRate(address user) public view returns (uint256) {
        if (stETHPool.getBorrowedOf(user) == 0) return 1e22;
        return
            (stETHPool.depositedEther(user) * getEtherPrice() * 1e12) /
            stETHPool.getBorrowedOf(user);
    }

    function getExcessIncomeAmount()
        external
        view
        returns (uint256 eusdAmount)
    {
        if (
            IERC20(lido).balanceOf(address(stETHPool)) < stETHPool.totalDepositedEther()
        ) {
            eusdAmount = 0;
        } else {
            eusdAmount =
                ((IERC20(lido).balanceOf(address(stETHPool)) -
                    stETHPool.totalDepositedEther()) * getEtherPrice()) /
                1e8;
        }
    }

    function getOverallCollateralRate() public view returns (uint256) {
        return
            (stETHPool.totalDepositedEther() * getEtherPrice() * 1e12) /
            stETHPool.totalSupply();
    }

    function getLiquidateableAmount(address user)
        external
        view
        returns (uint256 etherAmount, uint256 eusdAmount)
    {
        if (getCollateralRate(user) > 150 * 1e18) return (0, 0);
        if (
            getCollateralRate(user) >= 125 * 1e18 ||
            getOverallCollateralRate() >= 150 * 1e18
        ) {
            etherAmount = stETHPool.depositedEther(user) / 2;
            eusdAmount = (etherAmount * getEtherPrice()) / 1e8;
        } else {
            etherAmount = stETHPool.depositedEther(user);
            eusdAmount = (etherAmount * getEtherPrice()) / 1e8;
            if (getCollateralRate(user) >= 1e20) {
                eusdAmount = (eusdAmount * 1e20) / getCollateralRate(user);
            }
        }
    }

    function getRedeemableAmount(address user) external view returns (uint256) {
        if (!stETHPool.isRedemptionProvider(user)) return 0;
        return stETHPool.getBorrowedOf(user);
    }

    function getRedeemableAmounts(address[] calldata users)
        external
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            if (!stETHPool.isRedemptionProvider(users[i])) amounts[i] = 0;
            amounts[i] = stETHPool.getBorrowedOf(users[i]);
        }
    }

    function getLiquidateFund(address user, address pool)
        external
        view
        returns (uint256 eusdAmount)
    {
        uint256 appro = EUSD.allowance(user, address(pool));
        if (appro == 0) return 0;
        uint256 bal = stETHPool.balanceOf(user);
        eusdAmount = appro > bal ? bal : appro;
    }

    function getWithdrawableAmount(address user)
        external
        view
        returns (uint256)
    {
        if (stETHPool.getBorrowedOf(user) == 0) return stETHPool.depositedEther(user);
        if (getCollateralRate(user) <= 160 * 1e18) return 0;
        return
            (stETHPool.depositedEther(user) *
                (getCollateralRate(user) - 160 * 1e18)) /
            getCollateralRate(user);
    }

    function getEusdMintableAmount(address user)
        external
        view
        returns (uint256 eusdAmount)
    {
        if (getCollateralRate(user) <= 160 * 1e18) return 0;
        return
            (stETHPool.depositedEther(user) * getEtherPrice()) /
            1e6 /
            160 -
            stETHPool.getBorrowedOf(user);
    }

    function getStakingPoolAPR(
        address poolAddress,
        address lbr,
        address lpToken
    ) external view returns (uint256 apr) {
        uint256 pool_lp_stake = IERC20(poolAddress).totalSupply();
        uint256 rewardRate = IStakingRewards(poolAddress).rewardRate();
        uint256 lp_lbr_amount = IERC20(lbr).balanceOf(lpToken);
        uint256 lp_total_supply = IERC20(lpToken).totalSupply();
        apr =
            (lp_total_supply * rewardRate * 86400 * 365 * 1e6) /
            (pool_lp_stake * lp_lbr_amount * 2);
    }

    function getTokenPrice(address token, address UniPool, address wethAddress) external view returns (uint256 price) {
        uint256 token_in_pool = IERC20(token).balanceOf(UniPool);
        uint256 weth_in_pool = IERC20(wethAddress).balanceOf(UniPool);
        price = weth_in_pool * getEtherPrice() * 1e10 / token_in_pool;
    }
}
