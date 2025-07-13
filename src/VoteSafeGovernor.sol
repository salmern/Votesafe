// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorVotesQuorumFraction} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {QuadraticVotingHandler} from "./QuadraticVotingHandler.sol";

contract VoteSafeGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl,
    AccessControl
{
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    QuadraticVotingHandler public qvHandler;

    uint256 public proposalThresholdBPS;
    uint256 public emergencyProposalThresholdBPS;
    uint256 public constant MAX_ACTIONS_PER_PROPOSAL = 10;
    uint256 public emergencyVotingPeriod = 2 days;

    mapping(uint256 => bool) public emergencyProposals;
    bool public paused;

    event EmergencyProposalCreated(uint256 indexed proposalId, address indexed proposer, string reason);
    event EmergencyPaused(address indexed account);
    event EmergencyUnpaused(address indexed account);
    event ProposalThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    error InvalidProposalThreshold();
    error TooManyActions();
    error InsufficientProposalThreshold();
    error EmptyOptions();

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    constructor(
        IVotes _token,
        TimelockController _timelock,
        address _qvHandler,
        uint256 _proposalThresholdBPS,
        uint256 _emergencyProposalThresholdBPS
    )
        Governor("VoteSafeGovernor")
        GovernorSettings(1, 7 days, 0)
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(4)
        GovernorTimelockControl(_timelock)
    {
        if (_proposalThresholdBPS > 10000 || _emergencyProposalThresholdBPS >= _proposalThresholdBPS) {
            revert InvalidProposalThreshold();
        }
        qvHandler = QuadraticVotingHandler(_qvHandler);
        proposalThresholdBPS = _proposalThresholdBPS;
        emergencyProposalThresholdBPS = _emergencyProposalThresholdBPS;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        string[] memory options,
        bool useQuadraticVoting
    ) public whenNotPaused returns (uint256 proposalId) {
        if (targets.length > MAX_ACTIONS_PER_PROPOSAL) revert TooManyActions();

        uint256 requiredVotes = (token().getPastTotalSupply(block.number - 1) * proposalThresholdBPS) / 10000;
        if (getVotes(msg.sender, block.number - 1) < requiredVotes) revert InsufficientProposalThreshold();

        if (useQuadraticVoting && options.length == 0) revert EmptyOptions();

        proposalId = super.propose(targets, values, calldatas, description);

        if (useQuadraticVoting) {
            qvHandler.createQuadraticProposal(proposalId, description, options);
        }
    }

    function emergencyPause() external onlyRole(EMERGENCY_ROLE) {
        paused = true;
        emit EmergencyPaused(msg.sender);
    }

    function emergencyUnpause() external onlyRole(EMERGENCY_ROLE) {
        paused = false;
        emit EmergencyUnpaused(msg.sender);
    }

    function updateProposalThresholds(uint256 newThreshold, uint256 newEmergencyThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newThreshold > 10000 || newEmergencyThreshold >= newThreshold) revert InvalidProposalThreshold();
        emit ProposalThresholdUpdated(proposalThresholdBPS, newThreshold);
        proposalThresholdBPS = newThreshold;
        emergencyProposalThresholdBPS = newEmergencyThreshold;
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        uint256 totalSupply = token().getPastTotalSupply(block.number - 1);
        return (totalSupply * proposalThresholdBPS) / 10000;
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalDeadline(uint256 proposalId) public view override(Governor) returns (uint256) {
        if (emergencyProposals[proposalId]) return proposalSnapshot(proposalId) + emergencyVotingPeriod;
        return super.proposalDeadline(proposalId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(Governor, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }
}
