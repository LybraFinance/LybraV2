// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./EUSDbase.sol";
import "../../OFT/BaseOFTV2.sol";

interface ICrossChainPool {
    function deposit(address onBehalfOf, uint256 eusdAmount) external;
    function withdraw(address user, uint256 shareAmount) external;
}

contract EUSD is BaseOFTV2, EUSDbase {

    uint internal immutable ld2sdRate;
    ICrossChainPool chainPool;

    constructor(address _config, uint8 _sharedDecimals, address _lzEndpoint) EUSDbase(_config) BaseOFTV2(_sharedDecimals, _lzEndpoint) {
        uint8 decimals = decimals();
        require(_sharedDecimals <= decimals, "OFT: sharedDecimals must be <= decimals");
        ld2sdRate = 10 ** (decimals - _sharedDecimals);
    }

    /************************************************************************
    * public functions
    ************************************************************************/
    function circulatingSupply() public view virtual override returns (uint) {
        return totalSupply();
    }

    function token() public view virtual override returns (address) {
        return address(this);
    }

    function setMagicPool(address _pool) external onlyOwner {
        chainPool = ICrossChainPool(_pool);
    }

    /************************************************************************
    * internal functions
    ************************************************************************/
    function _debitFrom(address _from, uint16, bytes32, uint _share) internal virtual override returns (uint) {
        address spender = _msgSender();
        uint256 amount = getMintedEUSDByShares(_share);
        if (_from != spender) _spendAllowance(_from, spender, amount);

        _transfer(_from, address(chainPool), amount);
        chainPool.deposit(_from, _share);
        return _share;
    }

    function _creditTo(uint16, address _toAddress, uint _share) internal virtual override returns (uint) {
        if(_toAddress != address(this)) {
            chainPool.withdraw(_toAddress, _share);
        }
        return _share;
    }

    function _transferFrom(address _from, address _to, uint _share) internal virtual override returns (uint) {
        address spender = _msgSender();
        uint256 amount = getMintedEUSDByShares(_share);
        // if transfer from this contract, no need to check allowance
        if (_from != address(this) && _from != spender) _spendAllowance(_from, spender, amount);
        if(_from == address(this)) {
            chainPool.withdraw(_to, _share);
        } else {
            _transfer(_from, _to, amount);
        }
        return _share;
    }

    function _ld2sdRate() internal view virtual override returns (uint) {
        return ld2sdRate;
    }
}
