// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/governance/TimelockController.sol";


contract GovernanceTimelock is TimelockController {
    bytes32 public constant DAO = keccak256("DAO");
    bytes32 public constant TIMELOCK = keccak256("TIMELOCK");
    bytes32 public constant ADMIN = keccak256("ADMIN");

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address timeLock) TimelockController(minDelay, proposers, executors, msg.sender) {
        _setRoleAdmin(DAO, DAO);
        _setRoleAdmin(TIMELOCK, DAO);
        _setRoleAdmin(ADMIN, DAO);
        _grantRole(DAO, msg.sender);
        _grantRole(TIMELOCK, timeLock);
    }

    function checkRole(bytes32 role, address _sender) public view  returns(bool){
        return hasRole(role, _sender) || hasRole(DAO, _sender);
    }

    function checkOnlyRole(bytes32 role, address _sender) public view  returns(bool){
        return hasRole(role, _sender);
    }
  
}