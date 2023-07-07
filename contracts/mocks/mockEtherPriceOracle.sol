// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract mockEtherPriceOracle {
    function decimals() external view returns (uint8){
        return 8;
    }

  function description() external view returns (string memory){
    return "desc";
  }

  function version() external view returns (uint256){
    return 1;
  }



  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    ){
        return (1, 1800 * 1e8, 1687380923, 1687380923, 1 );
    }
}