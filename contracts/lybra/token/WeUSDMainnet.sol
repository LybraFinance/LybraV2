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

    uint256 public totalCrossChainAmount;

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

    function onOFTReceived(uint16, bytes calldata, uint64, bytes32, uint _amount, bytes calldata _payload) external {
        require(msg.sender == address(this), "");
        address to = abi.decode(_payload, (address));
        _burn(address(this), _amount);
        EUSD.transferShares(to, _amount);
    }

    /************************************************************************
    * public functions
    ************************************************************************/
    function sendFrom(address _from, uint16 _dstChainId, bytes32 _toAddress, uint _amount, LzCallParams calldata _callParams) public payable override {
        require(totalCrossChainAmount + _amount <= configurator.getWeUSDMaxSupplyOnL2(), "ESL");
        totalCrossChainAmount += _amount;
        _send(_from, _dstChainId, _toAddress, _amount, _callParams.refundAddress, _callParams.zroPaymentAddress, _callParams.adapterParams);
    }

    function sendAndCall(address _from, uint16 _dstChainId, bytes32 _toAddress, uint _amount, bytes calldata _payload, uint64 _dstGasForCall, LzCallParams calldata _callParams) public payable override {
        require(totalCrossChainAmount + _amount <= configurator.getWeUSDMaxSupplyOnL2(), "ESL");
        totalCrossChainAmount += _amount;
        _sendAndCall(_from, _dstChainId, _toAddress, _amount, _payload, _dstGasForCall, _callParams.refundAddress, _callParams.zroPaymentAddress, _callParams.adapterParams);
    }

    function getMintAmount(uint256 eusdAmount) public view returns (uint256 weusdAmount) {
        weusdAmount = EUSD.getSharesByMintedEUSD(eusdAmount);
    }

    function getEUSDValue() public view returns (uint256 eusdAmount) {
        eusdAmount = EUSD.getMintedEUSDByShares(1e18);
    }

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
        _burn(_from, _amount);
        return _amount;
    }

    function _creditTo(uint16, address _toAddress, uint _amount) internal virtual override returns (uint) {
        _mint(_toAddress, _amount);
        totalCrossChainAmount -= _amount;
        return _amount;
    }

    function _transferFrom(address _from, address _to, uint _amount) internal virtual override returns (uint) {
        address spender = _msgSender();
        // if transfer from this contract, no need to check allowance
        if (_from != address(this) && _from != spender) _spendAllowance(_from, spender, _amount);
        if(_from != _to) {
            _transfer(_from, _to, _amount);
        }
        return _amount;
    }

    function _ld2sdRate() internal view virtual override returns (uint) {
        return ld2sdRate;
    }
}
