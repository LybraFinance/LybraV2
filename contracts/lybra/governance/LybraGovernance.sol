// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "../interfaces/IesLBR.sol";
import "../interfaces/IGovernanceTimelock.sol";

contract LybraGovernance is GovernorTimelockControl {
    
    IesLBR public esLBR;
    IGovernanceTimelock public GovernanceTimelock;

    /// @notice Ballot receipt record for a voter
    struct Receipt {
        /// @notice Whether or not a vote has been cast
        bool hasVoted;

        /// @notice Whether or not the voter supports the proposal or abstains
        uint8 support;

        /// @notice The number of votes the voter had, which were cast
        uint256 votes;
    }
    

    struct ProposalExtraData {
        mapping(address => Receipt)  receipts;
        mapping(uint8 => uint256) supportVotes;
        uint256 totalVotes;
    }

    mapping (uint256 => ProposalExtraData) public proposalData;
     


        // TimelockController timelockAddress;
      constructor(string memory name_, TimelockController timelock_, address _esLBR) GovernorTimelockControl(timelock_)  Governor(name_) {
        // timelock = timelock_;
        esLBR = IesLBR(_esLBR);
        GovernanceTimelock = IGovernanceTimelock(address(timelock_));
    }

      /**
     * @notice module:user-config
     * @dev Minimum number of cast voted required for a proposal to be successful.
     *
     * NOTE: The `timepoint` parameter corresponds to the snapshot used for counting vote. This allows to scale the
     * quorum depending on values such as the totalSupply of a token at this timepoint (see {ERC20Votes}).
     */
    function quorum(uint256 timepoint) public view override returns (uint256){
        return esLBR.getPastTotalSupply(timepoint) / 3;
    }

    
    /**
     * @dev Amount of votes already cast passes the threshold limit.
     */
    function _quorumReached(uint256 proposalId) internal view override returns (bool){
        return proposalData[proposalId].supportVotes[1] + proposalData[proposalId].supportVotes[2] >= quorum(proposalSnapshot(proposalId));
    }

       /**
     * @dev Is the proposal successful or not.
     */
    function _voteSucceeded(uint256 proposalId) internal view override returns (bool){
        return _quorumReached(proposalId) && proposalData[proposalId].supportVotes[1] + proposalData[proposalId].supportVotes[2] > proposalData[proposalId].supportVotes[0] && clock() > proposalDeadline(proposalId);
    }

       /**
     * @dev Register a vote for `proposalId` by `account` with a given `support`, voting `weight` and voting `params`.
     *
     * Note: Support is generic and can represent various things depending on the voting system used.
     */

    function _countVote(uint256 proposalId, address account, uint8 support, uint256 weight, bytes memory) internal override {
      
        require(state(proposalId) == ProposalState.Active, "GovernorBravo::castVoteInternal: voting is closed");
        require(support <= 2, "GovernorBravo::castVoteInternal: invalid vote type");
        ProposalExtraData storage proposalExtraData = proposalData[proposalId];
        Receipt storage receipt = proposalExtraData.receipts[account];
        require(receipt.hasVoted == false, "GovernorBravo::castVoteInternal: voter already voted");
        
        proposalExtraData.supportVotes[support] += weight;
       

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = weight;
        proposalExtraData.totalVotes += weight;
        
    }

    /**
     * @dev Get the voting weight of `account` at a specific `timepoint`, for a vote as described by `params`.
     */

     function _getVotes(address account, uint256 timepoint, bytes memory) internal view override returns (uint256){

        return esLBR.getPastVotes(account, timepoint);
     }

    /**
     * @dev Overridden execute function that run the already queued proposal through the timelock.
     */
    function _execute(uint256 /* proposalId */, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) internal virtual override {
        require(GovernanceTimelock.checkOnlyRole(keccak256("TIMELOCK"), msg.sender), "not authorized");
        super._execute(1, targets, values, calldatas, descriptionHash);
        // _timelock.executeBatch{value: msg.value}(targets, values, calldatas, 0, descriptionHash);
    }

     function getSupportVotes(uint256 proposalId, uint8 support) public view returns (uint256){
         return proposalData[proposalId].supportVotes[support];
     }

    /**
     * @notice module:user-config
     * @dev Delay between the vote start and vote end. The unit this duration is expressed in depends on the clock
     * (see EIP-6372) this contract uses.
     *
     * NOTE: The {votingDelay} can delay the start of the vote. This must be considered when setting the voting
     * duration compared to the voting delay.
     */
    function votingPeriod() public pure override returns (uint256){
         return 3;
    }

     function votingDelay() public pure override returns (uint256){
         return 1;
    }

     function CLOCK_MODE() public override view returns (string memory){
       require(clock() == block.number, "Votes: broken clock mode");
        return "mode=blocknumber&from=default";
    }

    function COUNTING_MODE() public override view virtual returns (string memory){
          return "support=bravo&quorum=for,abstain";
    }

    
    function clock() public override view returns (uint48){
        return SafeCast.toUint48(block.number);
    }

    function hasVoted(uint256 proposalId, address account) public override view virtual returns (bool){
        return proposalData[proposalId].receipts[account].hasVoted;
    }

    /**
     * @dev Part of the Governor Bravo's interface: _"The number of votes required in order for a voter to become a proposer"_.
     */
    function proposalThreshold() public pure override returns (uint256) {
        return 1e23;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(GovernorTimelockControl) returns (bool) {
        bytes4 governorCancelId = this.cancel.selector ^ this.proposalProposer.selector;

        bytes4 governorParamsId = this.castVoteWithReasonAndParams.selector ^
            this.castVoteWithReasonAndParamsBySig.selector ^
            this.getVotesWithParams.selector;

        // The original interface id in v4.3.
        bytes4 governor43Id = type(IGovernor).interfaceId ^
            type(IERC6372).interfaceId ^
            governorCancelId ^
            governorParamsId;

        // An updated interface id in v4.6, with params added.
        bytes4 governor46Id = type(IGovernor).interfaceId ^ type(IERC6372).interfaceId ^ governorCancelId;

        // For the updated interface id in v4.9, we use governorCancelId directly.

        return
            interfaceId == governor43Id ||
            interfaceId == governor46Id ||
            interfaceId == governorCancelId ||
            interfaceId == type(IERC1155Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }


}