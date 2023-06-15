// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/governance/TimelockController.sol";


contract GovernanceTimelock is TimelockController {
    // contructor()
    bytes32 public constant DAO = keccak256("DAO");
    bytes32 public constant TIMELOCK = keccak256("TIMELOCK");
    bytes32 public constant ADMIN = keccak256("ADMIN");
    bytes32 public constant GOV = keccak256("GOV");

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin) TimelockController(minDelay, proposers, executors, admin) {
       
        _setRoleAdmin(DAO, GOV);
        _setRoleAdmin(TIMELOCK, GOV);
        _setRoleAdmin(ADMIN, GOV);
        _grantRole(DAO, address(this));
        _grantRole(DAO, msg.sender);
        _grantRole(GOV, msg.sender);
    }

    function checkRole(bytes32 role, address _sender) public view  returns(bool){
        return hasRole(role, _sender) || hasRole(DAO, _sender);
    }

    function checkOnlyRole(bytes32 role, address _sender) public view  returns(bool){
        return hasRole(role, _sender);
    }
  
}