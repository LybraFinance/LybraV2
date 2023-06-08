// SPDX-License-Identifier: GPL-3.0

/**
 * @title PeUSD Token
 * @dev PeUSD is a stable, interest-free ERC20-like token minted through eUSD in the Lybra protocol.
 * It is pegged to 1 USD and does not undergo rebasing.
 * PeUSD can be minted and burned through non-rebasing asset pools.
 * Additionally, PeUSD can be minted in equivalent amounts by depositing eUSD.
 * The contract keeps track of the totalShares of eUSD deposited by users and the totalMinted PeUSD.
 * When users redeem PeUSD, they can retrieve the corresponding proportion of eUSD.
 * As a result, users can utilize PeUSD without sacrificing the yield on their eUSD holdings.
 */

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../OFT/BaseOFTV2.sol";
import "../interfaces/Iconfigurator.sol";
import "../interfaces/IEUSD.sol";

interface FlashBorrower {
    /// @notice Flash loan callback
    /// @param amount The amount of tokens received
    /// @param data Forwarded data from the flash loan request
    /// @dev Called after receiving the requested flash loan, should return tokens + any fees before the end of the transaction
    function onFlashLoan(uint256 amount, bytes calldata data) external;
}

contract PeUSDMainnet is BaseOFTV2, ERC20 {
    IEUSD public immutable EUSD;
    Iconfigurator public immutable configurator;
    uint internal immutable ld2sdRate;
    mapping(address => ConvertInfo) public userConvertInfo;

    struct ConvertInfo {
        uint256 depositedEUSDShares;
        uint256 mintedPeUSD;
    }

    event Flashloaned(
        FlashBorrower indexed receiver,
        uint256 borrowShares,
        uint256 burnAmount
    );

    modifier onlyMintVault() {
        require(configurator.mintVault(msg.sender), "RCP");
        _;
    }
    modifier MintPaused() {
        require(!configurator.vaultMintPaused(msg.sender), "MPP");
        _;
    }
    modifier BurnPaused() {
        require(!configurator.vaultBurnPaused(msg.sender), "BPP");
        _;
    }

    constructor(
        address _config,
        uint8 _sharedDecimals,
        address _lzEndpoint
    ) ERC20("peg-eUSD", "PeUSD") BaseOFTV2(_sharedDecimals, _lzEndpoint) {
        configurator = Iconfigurator(_config);
        EUSD = IEUSD(configurator.getEUSDAddress());
        uint8 decimals = decimals();
        require(
            _sharedDecimals <= decimals,
            "OFT: sharedDecimals must be <= decimals"
        );
        ld2sdRate = 10 ** (decimals - _sharedDecimals);
    }

    function mint(
        address to,
        uint256 amount
    ) external onlyMintVault MintPaused returns (bool) {
        require(to != address(0), "TZA");
        _mint(to, amount);
        return true;
    }

    function burn(
        address account,
        uint256 amount
    ) external onlyMintVault BurnPaused returns (bool) {
        _burn(account, amount);
        return true;
    }

    /**
     * @notice Allows the user to deposit eUSD and mint PeUSD tokens.
     * @param user The address of the user who wants to deposit eUSD and mint PeUSD. It can only be the contract itself or the msg.sender.
     * @param eusdAmount The amount of eUSD to deposit and mint PeUSD tokens.
     */
    function convertToPeUSD(address user, uint256 eusdAmount) public {
        require(_msgSender() == user || _msgSender() == address(this), "MDM");
        require(
            EUSD.balanceOf(address(this)) + eusdAmount <=
                configurator.getEUSDMaxLocked(),
            "ESL"
        );
        bool success = EUSD.transferFrom(user, address(this), eusdAmount);
        require(success, "TF");
        uint256 share = EUSD.getSharesByMintedEUSD(eusdAmount);
        userConvertInfo[user].depositedEUSDShares += share;
        userConvertInfo[user].mintedPeUSD += eusdAmount;
        _mint(user, eusdAmount);
    }

    /**
     * @dev Allows users to deposit eUSD and mint PeUSD tokens, which can be directly bridged to other networks.
     * @param eusdAmount The amount of eUSD to deposit and mint PeUSD tokens.
     * @param dstChainId The chain ID of the target network.
     * @param toAddress The receiving address after cross-chain transfer.
     * @param callParams Additional parameters.
     */
    function convertToPeUSDAndCrossChain(
        uint256 eusdAmount,
        uint16 dstChainId,
        bytes32 toAddress,
        LzCallParams calldata callParams
    ) external payable {
        convertToPeUSD(_msgSender(), eusdAmount);
        sendFrom(_msgSender(), dstChainId, toAddress, eusdAmount, callParams);
    }

    /**
     * @dev Allows users to repay PeUSD tokens and retrieve eUSD.
     * @param peusdAmount The amount of PeUSD tokens to burn and retrieve eUSD. The user's balance of PeUSD tokens must be greater than or equal to this amount.
     * Requirements:
     * `peusdAmount` must be greater than 0.
     * The user's `mintedPeUSD` must be greater than or equal to `peusdAmount`.
     */
    function convertToEUSD(uint256 peusdAmount) external {
        require(
            peusdAmount <= userConvertInfo[msg.sender].mintedPeUSD &&
                peusdAmount > 0,
            "PCE"
        );
        _burn(msg.sender, peusdAmount);
        uint256 share = (userConvertInfo[msg.sender].depositedEUSDShares *
            peusdAmount) / userConvertInfo[msg.sender].mintedPeUSD;
        userConvertInfo[msg.sender].mintedPeUSD -= peusdAmount;
        userConvertInfo[msg.sender].depositedEUSDShares -= share;
        EUSD.transferShares(msg.sender, share);
    }

    /**
     * @dev Allows users to lend out any amount of eUSD for flash loan calls.
     * @param receiver The address of the contract that will receive the borrowed eUSD.
     * @param eusdAmount The amount of eUSD to lend out.
     * @param data The data to be passed to the receiver contract for execution.
     */
    function executeFlashloan(
        FlashBorrower receiver,
        uint256 eusdAmount,
        bytes calldata data
    ) public payable {
        uint256 shareAmount = EUSD.getSharesByMintedEUSD(eusdAmount);
        EUSD.transferShares(address(receiver), shareAmount);
        receiver.onFlashLoan(shareAmount, data);
        bool success = EUSD.transferFrom(
            address(receiver),
            address(this),
            EUSD.getMintedEUSDByShares(shareAmount)
        );
        require(success, "TF");

        uint256 burnShare = getFee(shareAmount);
        EUSD.burnShares(address(receiver), burnShare);
        emit Flashloaned(receiver, eusdAmount, burnShare);
    }

    /************************************************************************
     * view functions
     ************************************************************************/

    /// @notice Calculate the fee owed for the loaned tokens
    /// @return The amount of shares you need to pay as a fee
    function getFee(uint256 share) public view returns (uint256) {
        return (share * configurator.flashloanFee()) / 10_000;
    }

    /**
     * @dev Returns the interest of eUSD locked by the user.
     * @param user The address of the user.
     * @return eusdAmount The interest earned by the user.
     */
    function getAccruedEUSDInterest(
        address user
    ) public view returns (uint256 eusdAmount) {
        return
            EUSD.getMintedEUSDByShares(
                userConvertInfo[user].depositedEUSDShares
            ) - userConvertInfo[user].mintedPeUSD;
    }

    function circulatingSupply() public view virtual override returns (uint) {
        return totalSupply();
    }

    function token() public view virtual override returns (address) {
        return address(this);
    }

    /************************************************************************
     * internal functions
     * @dev The following functions are internal functions of Layer Zero OFT, used for internal calls during cross-chain operations.
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
