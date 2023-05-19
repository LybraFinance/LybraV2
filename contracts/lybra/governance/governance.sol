// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract Governance is AccessControl {
    bytes32 public constant DAO = keccak256("DAO");
    bytes32 public constant TIMELOCK = keccak256("TIMELOCK");
    bytes32 public constant ADMIN = keccak256("ADMIN");

    constructor(address _dao) {
        _setRoleAdmin(DAO, DAO);
        _setRoleAdmin(TIMELOCK, DAO);
        _setRoleAdmin(ADMIN, DAO);
        _grantRole(DAO, _dao);
        _grantRole(DAO, msg.sender);
    }

    modifier checkRole(bytes32 role) {
        require(hasRole(role, _msgSender()) || hasRole(DAO, _msgSender()), "No authority.");
        _;
    }
}