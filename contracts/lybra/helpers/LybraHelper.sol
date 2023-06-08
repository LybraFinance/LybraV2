// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;

import "../interfaces/Iconfigurator.sol";
import "../interfaces/IEUSD.sol";
import "../interfaces/ILybra.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IStakingRewards {
    function rewardRate() external view returns (uint256);
}

contract LybraHelper is Ownable {
    Iconfigurator public immutable configurator;
    address[] public pools;
    address public lido;
    address public ethlbrStakePool;
    address public ethlbrLpToken;
    AggregatorV3Interface internal priceFeed =
        AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

    constructor(address _lido, address _config) {
        lido = _lido;
        configurator = Iconfigurator(_config);
    }

    function setPools(address[] memory _pools) external onlyOwner {
        pools = _pools;
    }

    function setEthlbrStakePool(address _pool, address _lp) external onlyOwner {
        ethlbrStakePool = _pool;
        ethlbrLpToken = _lp;
    }

    function getAssetPrice(address pool) public view returns (uint256) {
        if (ILybra(pool).getBorrowType() == 1) {
            (, /* uint80 roundID */ int price, , , ) = /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
            priceFeed.latestRoundData();
            return uint256(price);
        } else {
            return 0;
        }
    }

    function getTotalStakedOf(address user) external view returns (uint256) {
        uint256 amount;
        for (uint i = 0; i < pools.length; i++) {
            ILybra pool = ILybra(pools[i]);
            uint borrowed = pool.getBorrowedOf(user);
            if (pool.getBorrowType() == 1) {
                borrowed = IEUSD(configurator.getEUSDAddress())
                    .getMintedEUSDByShares(borrowed);
            }
            amount += borrowed;
        }
        return amount;
    }

    function getCollateralRate(
        address user,
        address pool
    ) public view returns (uint256) {
        ILybra lybraPool = ILybra(pool);
        if (lybraPool.getBorrowType() != 0) return 0;
        if (lybraPool.getBorrowedOf(user) == 0) return 1e22;
        return
            (lybraPool.depositedAsset(user) * getAssetPrice(pool) * 1e12) /
            lybraPool.getBorrowedOf(user);
    }

    function getExcessIncomeAmount(
        address pool
    ) external view returns (uint256 eusdAmount) {
        ILybra lybraPool = ILybra(pool);
        if (lybraPool.getBorrowType() != 0) return 0;
        address asset = lybraPool.getAsset();
        if (
            IERC20(asset).balanceOf(address(pool)) <
            lybraPool.totaldepositedAsset()
        ) {
            eusdAmount = 0;
        } else {
            eusdAmount =
                ((IERC20(asset).balanceOf(pool) -
                    lybraPool.totaldepositedAsset()) * getAssetPrice(pool)) /
                1e8;
        }
    }

    function getOverallCollateralRate(
        address pool
    ) public view returns (uint256) {
        ILybra lybraPool = ILybra(pool);
        return
            (lybraPool.totaldepositedAsset() * getAssetPrice(pool) * 1e12) /
            lybraPool.poolTotalEUSDCirculation();
    }

    function getLiquidateableAmount(
        address user,
        address pool
    ) external view returns (uint256 etherAmount, uint256 eusdAmount) {
        ILybra lybraPool = ILybra(pool);
        if (getCollateralRate(user, pool) > 150 * 1e18) return (0, 0);
        if (
            getCollateralRate(user, pool) >= 125 * 1e18 ||
            getOverallCollateralRate(pool) >= 150 * 1e18
        ) {
            etherAmount = lybraPool.depositedAsset(user) / 2;
            eusdAmount = (etherAmount * getAssetPrice(pool)) / 1e8;
        } else {
            etherAmount = lybraPool.depositedAsset(user);
            eusdAmount = (etherAmount * getAssetPrice(pool)) / 1e8;
            if (getCollateralRate(user, pool) >= 1e20) {
                eusdAmount =
                    (eusdAmount * 1e20) /
                    getCollateralRate(user, pool);
            }
        }
    }

    // function getRedeemableAmount(address user) external view returns (uint256) {
    //     if (!stETHPool.isRedemptionProvider(user)) return 0;
    //     return stETHPool.getBorrowedOf(user);
    // }

    // function getRedeemableAmounts(address[] calldata users)
    //     external
    //     view
    //     returns (uint256[] memory amounts)
    // {
    //     amounts = new uint256[](users.length);
    //     for (uint256 i = 0; i < users.length; i++) {
    //         if (!stETHPool.isRedemptionProvider(users[i])) amounts[i] = 0;
    //         amounts[i] = stETHPool.getBorrowedOf(users[i]);
    //     }
    // }

    function getLiquidateFund(
        address user,
        address pool
    ) external view returns (uint256 eusdAmount) {
        uint256 appro = IEUSD(configurator.getEUSDAddress()).allowance(
            user,
            address(pool)
        );
        if (appro == 0) return 0;
        uint256 bal = IEUSD(configurator.getEUSDAddress()).balanceOf(user);
        eusdAmount = appro > bal ? bal : appro;
    }

    function getWithdrawableAmount(
        address user,
        address pool
    ) external view returns (uint256) {
        ILybra lybraPool = ILybra(pool);
        if (lybraPool.getBorrowedOf(user) == 0)
            return lybraPool.depositedAsset(user);
        uint256 safeCollateralRate = lybraPool.safeCollateralRate();
        if (getCollateralRate(user, pool) <= safeCollateralRate) return 0;
        return
            (lybraPool.depositedAsset(user) *
                (getCollateralRate(user, pool) - safeCollateralRate)) /
            getCollateralRate(user, pool);
    }

    function getEusdMintableAmount(
        address user,
        address pool
    ) external view returns (uint256 eusdAmount) {
        ILybra lybraPool = ILybra(pool);
        uint256 safeCollateralRate = lybraPool.safeCollateralRate();
        if (getCollateralRate(user, pool) <= safeCollateralRate) return 0;
        return
            (lybraPool.depositedAsset(user) * getAssetPrice(pool)) /
            1e24 /
            safeCollateralRate -
            lybraPool.getBorrowedOf(user);
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

    function getTokenPrice(
        address token,
        address UniPool,
        address wethAddress
    ) external view returns (uint256 price) {
        uint256 token_in_pool = IERC20(token).balanceOf(UniPool);
        uint256 weth_in_pool = IERC20(wethAddress).balanceOf(UniPool);
        price =
            (weth_in_pool * getAssetPrice(msg.sender) * 1e10) /
            token_in_pool;
    }
}
