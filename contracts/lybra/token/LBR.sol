// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.17;
/**
 * @title LBR is an ERC20-compliant token.
 * - LBR can only be exchanged to esLBR in the lybraFund contract.
 * - Apart from the initial production, LBR can only be produced by destroying esLBR in the fund contract.
 */
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interfaces/Iconfigurator.sol";
import "../../OFT/BaseOFTV2.sol";

contract LBR is BaseOFTV2, ERC20 {
    Iconfigurator public immutable configurator;
    uint256 maxSupply = 100_000_000 * 1e18;
    uint internal immutable ld2sdRate;

    constructor(
        address _config,
        uint8 _sharedDecimals,
        address _lzEndpoint
    ) ERC20("LBR", "LBR") BaseOFTV2(_sharedDecimals, _lzEndpoint) {
        configurator = Iconfigurator(_config);
        uint8 decimals = decimals();
        require(
            _sharedDecimals <= decimals,
            "OFT: sharedDecimals must be <= decimals"
        );
        ld2sdRate = 10 ** (decimals - _sharedDecimals);
    }

    function mint(address user, uint256 amount) external returns (bool) {
        require(configurator.tokenMiner(msg.sender), "not authorized");
        require(
            totalSupply() + amount <= maxSupply,
            "exceeding the maximum supply quantity."
        );
        _mint(user, amount);
        return true;
    }

    function burn(address user, uint256 amount) external returns (bool) {
        require(configurator.tokenMiner(msg.sender), "not authorized");
        _burn(user, amount);
        return true;
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
    function _debitFrom(
        address _from,
        uint16,
        bytes32,
        uint _amount
    ) internal virtual override returns (uint) {
        address spender = _msgSender();
        if (_from != spender) _spendAllowance(_from, spender, _amount);
        _burn(_from, _amount);
        return _amount;
    }

    function _creditTo(
        uint16,
        address _toAddress,
        uint _amount
    ) internal virtual override returns (uint) {
        _mint(_toAddress, _amount);
        return _amount;
    }

    function _transferFrom(
        address _from,
        address _to,
        uint _amount
    ) internal virtual override returns (uint) {
        address spender = _msgSender();
        // if transfer from this contract, no need to check allowance
        if (_from != address(this) && _from != spender)
            _spendAllowance(_from, spender, _amount);
        _transfer(_from, _to, _amount);
        return _amount;
    }

    function _ld2sdRate() internal view virtual override returns (uint) {
        return ld2sdRate;
    }
}
