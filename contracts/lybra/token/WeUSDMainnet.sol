// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../OFT/BaseOFTV2.sol";
import "../interfaces/Iconfigurator.sol";
import "../interfaces/IEUSD.sol";

interface ICrossChainPool {
    function deposit(address onBehalfOf, uint256 eusdAmount) external;
    function withdraw(address user, uint256 shareAmount) external;
}

contract WeUSDMainnet is BaseOFTV2, ERC20 {
    IEUSD public immutable EUSD;
    Iconfigurator public immutable configurator;
    uint internal immutable ld2sdRate;
    ICrossChainPool chainPool;

    constructor(address _eusd, address _config, uint8 _sharedDecimals, address _lzEndpoint) ERC20("Wrapped eUSD", "WeUSD") BaseOFTV2(_sharedDecimals, _lzEndpoint) {
        EUSD = IEUSD(_eusd);
        configurator = Iconfigurator(_config);
        uint8 decimals = decimals();
        require(_sharedDecimals <= decimals, "OFT: sharedDecimals must be <= decimals");
        ld2sdRate = 10 ** (decimals - _sharedDecimals);
    }

    function convertToWeUSD(uint256 eusdAmount) external {
        bool success = EUSD.transferFrom(msg.sender, address(this), eusdAmount);
        require(success, "TF");
        _mint(msg.sender, getMintAmount(eusdAmount));
    }

    function convertToEUSD(uint256 weusdAmount) external {
        _burn(msg.sender, weusdAmount);
        EUSD.transferShares(msg.sender, weusdAmount);
    }

    function convertToWeUSDAndCrossChain(uint256 eusdAmount, uint16 _dstChainId, bytes32 _toAddress, LzCallParams calldata _callParams) external payable {
        bool success = EUSD.transferFrom(msg.sender, address(this), eusdAmount);
        require(success, "TF");
        uint256 weUSDAmount = getMintAmount(eusdAmount);
        _mint(msg.sender, weUSDAmount);
        sendFrom(msg.sender, _dstChainId, _toAddress, weUSDAmount, _callParams);
    }

    function getMintAmount(uint256 eusdAmount) public view returns (uint256 weusdAmount) {
        weusdAmount = EUSD.getSharesByMintedEUSD(eusdAmount);
    }

    function getPrice() public view returns (uint256 eusdAmount) {
        eusdAmount = EUSD.getMintedEUSDByShares(1e18);
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

    

    /************************************************************************
    * internal functions
    ************************************************************************/
    function _debitFrom(address _from, uint16, bytes32, uint _amount) internal virtual override returns (uint) {
        address spender = _msgSender();
        if (_from != spender) _spendAllowance(_from, spender, _amount);

        _transfer(_from, configurator.crossChainPool(), _amount);
        ICrossChainPool(configurator.crossChainPool()).deposit(_from, _amount);
        return _amount;
    }

    function _creditTo(uint16, address _toAddress, uint _amount) internal virtual override returns (uint) {
        if(_toAddress != address(this)) {
            ICrossChainPool(configurator.crossChainPool()).withdraw(_toAddress, _amount);
        }
        return _amount;
    }

    function _transferFrom(address _from, address _to, uint _amount) internal virtual override returns (uint) {
        address spender = _msgSender();
        // if transfer from this contract, no need to check allowance
        if (_from != address(this) && _from != spender) _spendAllowance(_from, spender, _amount);
        if(_from == address(this)) {
            ICrossChainPool(configurator.crossChainPool()).withdraw(_to, _amount);
        } else {
            _transfer(_from, _to, _amount);
        }
        return _amount;
    }

    function _ld2sdRate() internal view virtual override returns (uint) {
        return ld2sdRate;
    }
}
