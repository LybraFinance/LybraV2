// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

interface IGovernanceTimelock {
   function checkRole(bytes32 role, address sender) external view returns(bool);
   function checkOnlyRole(bytes32 role, address sender) external view returns(bool);
}