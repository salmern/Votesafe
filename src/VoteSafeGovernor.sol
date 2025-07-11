// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

interface IQuadraticVoting {
    function createProposal(string memory title, string memory description, string[] memory options, uint256 duration)
        external
        returns (uint256);

    function getProposal(uint256 proposalId)
        external
        view
        returns (
            uint256 id,
            string memory title,
            string memory description,
            address proposer,
            uint256 startTime,
            uint256 endTime,
            uint256 totalTokensAllocated,
            uint256 totalVotingPower,
            string[] memory options,
            uint256[] memory optionVotes,
            bool executed
        );

    function getWinningOption(uint256 proposalId) external view returns (uint256 winningOption, uint256 votes);

    function isProposalActive(uint256 proposalId) external view returns (bool);

    function getProposalCount() external view returns (uint256);
}

contract VoteSafeGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl,
    AccessControl,
    ReentrancyGuard
{
    using Strings for uint256;

    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant PROPOSAL_MANAGER_ROLE = keccak256("PROPOSAL_MANAGER_ROLE");

    IQuadraticVoting public immutable quadraticVoting;
    uint256 public proposalThresholdBPS;
    uint256 public emergencyProposalThresholdBPS;
    uint256 public constant MAX_ACTIONS_PER_PROPOSAL = 10;
    uint256 public emergencyVotingPeriod;

    mapping(uint256 => uint256) public proposalToQuadraticId;
    mapping(uint256 => QuadraticResult) public quadraticResults;
    mapping(uint256 => bool) public emergencyProposals;

    enum ProposalType {
        REGULAR,
        EMERGENCY,
        BATCH
    }

    struct QuadraticResult {
        uint256 quadraticProposalId;
        uint256 winningOption;
        uint256 totalVotes;
        bool processed;
    }

    struct ProposalMetadata {
        ProposalType proposalType;
        uint256 createdAt;
        uint256 quadraticVotingId;
        string[] options;
        bool useQuadraticVoting;
    }

    mapping(uint256 => ProposalMetadata) public proposalMetadata;

    event ProposalCreatedWithQuadratic(
        uint256 indexed proposalId, uint256 indexed quadraticProposalId, address indexed proposer
    );

    event QuadraticResultProcessed(
        uint256 indexed proposalId, uint256 indexed quadraticProposalId, uint256 winningOption, uint256 totalVotes
    );

    event EmergencyProposalCreated(uint256 indexed proposalId, address indexed proposer, string reason);

    event ProposalThresholdUpdated(
        uint256 oldThreshold, uint256 newThreshold, uint256 oldEmergencyThreshold, uint256 newEmergencyThreshold
    );

    event EmergencyVotingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    event EmergencyPaused(address indexed account);
    event EmergencyUnpaused(address indexed account);

    error InvalidProposalThreshold();
    error TooManyActions();
    error InvalidQuadraticVotingContract();
    error QuadraticResultNotReady();
    error InvalidEmergencyProposal();
    error ProposalAlreadyProcessed();
    error InsufficientProposalThreshold();
    error InvalidProposalType();
    error InvalidVotingPeriod();
    error UnauthorizedAccess();
    error NoQuadraticVotingForProposal();
    error EmptyOptions();
    error InvalidOptionsLength();

    bool public paused;

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    constructor(
        IVotes _token,
        TimelockController _timelock,
        IQuadraticVoting _quadraticVoting,
        uint256 _proposalThresholdBPS,
        uint256 _emergencyProposalThresholdBPS
    )
        Governor("VoteSafeGovernor")
        GovernorSettings(
            1, // 1 block voting delay
            7 days, // 7 days voting period
            0 // 0 proposal threshold (handled by custom logic)
        )
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(4)
        GovernorTimelockControl(_timelock)
    {
        if (address(_quadraticVoting) == address(0)) {
            revert InvalidQuadraticVotingContract();
        }
        if (_proposalThresholdBPS > 10000 || _emergencyProposalThresholdBPS > 10000) {
            revert InvalidProposalThreshold();
        }
        if (_emergencyProposalThresholdBPS >= _proposalThresholdBPS) {
            revert InvalidProposalThreshold();
        }

        quadraticVoting = _quadraticVoting;
        proposalThresholdBPS = _proposalThresholdBPS;
        emergencyProposalThresholdBPS = _emergencyProposalThresholdBPS;
        emergencyVotingPeriod = 2 days;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(PROPOSAL_MANAGER_ROLE, msg.sender);
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        string[] memory options,
        bool useQuadraticVoting
    ) public whenNotPaused returns (uint256 proposalId) {
        if (targets.length > MAX_ACTIONS_PER_PROPOSAL) {
            revert TooManyActions();
        }

        uint256 requiredVotes = (token().getPastTotalSupply(block.number - 1) * proposalThresholdBPS) / 10000;
        if (getVotes(msg.sender, block.number - 1) < requiredVotes) {
            revert InsufficientProposalThreshold();
        }

        if (useQuadraticVoting && options.length == 0) {
            revert EmptyOptions();
        }

        if (options.length > 20) {
            // Reasonable limit
            revert InvalidOptionsLength();
        }

        proposalId = super.propose(targets, values, calldatas, description);

        // Create a copy of options array for storage
        string[] memory optionsCopy = new string[](options.length);
        for (uint256 i = 0; i < options.length; i++) {
            optionsCopy[i] = options[i];
        }

        proposalMetadata[proposalId] = ProposalMetadata({
            proposalType: ProposalType.REGULAR,
            createdAt: block.timestamp,
            quadraticVotingId: 0,
            options: optionsCopy,
            useQuadraticVoting: useQuadraticVoting
        });

        if (useQuadraticVoting && options.length > 0) {
            _createQuadraticProposal(proposalId, description, options);
        }

        return proposalId;
    }

    function proposeEmergency(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        string memory reason
    ) external onlyRole(EMERGENCY_ROLE) whenNotPaused returns (uint256 proposalId) {
        if (targets.length > MAX_ACTIONS_PER_PROPOSAL) {
            revert TooManyActions();
        }

        uint256 requiredVotes = (token().getPastTotalSupply(block.number - 1) * emergencyProposalThresholdBPS) / 10000;
        if (getVotes(msg.sender, block.number - 1) < requiredVotes) {
            revert InsufficientProposalThreshold();
        }

        proposalId = super.propose(targets, values, calldatas, description);

        emergencyProposals[proposalId] = true;

        proposalMetadata[proposalId] = ProposalMetadata({
            proposalType: ProposalType.EMERGENCY,
            createdAt: block.timestamp,
            quadraticVotingId: 0,
            options: new string[](0),
            useQuadraticVoting: false
        });

        emit EmergencyProposalCreated(proposalId, msg.sender, reason);

        return proposalId;
    }

    function proposeBatch(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external whenNotPaused returns (uint256 proposalId) {
        if (targets.length > MAX_ACTIONS_PER_PROPOSAL) {
            revert TooManyActions();
        }

        uint256 requiredVotes = (token().getPastTotalSupply(block.number - 1) * proposalThresholdBPS) / 10000;
        if (getVotes(msg.sender, block.number - 1) < requiredVotes) {
            revert InsufficientProposalThreshold();
        }

        proposalId = super.propose(targets, values, calldatas, description);

        proposalMetadata[proposalId] = ProposalMetadata({
            proposalType: ProposalType.BATCH,
            createdAt: block.timestamp,
            quadraticVotingId: 0,
            options: new string[](0),
            useQuadraticVoting: false
        });

        return proposalId;
    }

    function processQuadraticResults(uint256 proposalId) external nonReentrant whenNotPaused {
        if (proposalToQuadraticId[proposalId] == 0) {
            revert NoQuadraticVotingForProposal();
        }

        if (quadraticResults[proposalId].processed) {
            revert ProposalAlreadyProcessed();
        }

        uint256 quadraticProposalId = proposalToQuadraticId[proposalId];

        // Check if quadratic voting period has ended
        (,,,,, uint256 endTime,,,,,) = quadraticVoting.getProposal(quadraticProposalId);
        if (block.timestamp < endTime) {
            revert QuadraticResultNotReady();
        }

        (uint256 winningOption, uint256 totalVotes) = quadraticVoting.getWinningOption(quadraticProposalId);

        quadraticResults[proposalId] = QuadraticResult({
            quadraticProposalId: quadraticProposalId,
            winningOption: winningOption,
            totalVotes: totalVotes,
            processed: true
        });

        emit QuadraticResultProcessed(proposalId, quadraticProposalId, winningOption, totalVotes);
    }

    function _createQuadraticProposal(uint256 proposalId, string memory description, string[] memory options)
        internal
    {
        string memory title = _extractTitle(description);
        uint256 quadraticProposalId = quadraticVoting.createProposal(title, description, options, votingPeriod());

        proposalToQuadraticId[proposalId] = quadraticProposalId;
        proposalMetadata[proposalId].quadraticVotingId = quadraticProposalId;

        emit ProposalCreatedWithQuadratic(proposalId, quadraticProposalId, msg.sender);
    }

    function _extractTitle(string memory description) internal pure returns (string memory) {
        bytes memory descBytes = bytes(description);
        if (descBytes.length == 0) return "Untitled Proposal";

        uint256 titleEnd = descBytes.length;
        uint256 maxLength = descBytes.length < 100 ? descBytes.length : 100;

        for (uint256 i = 0; i < maxLength; i++) {
            if (descBytes[i] == 0x0A || descBytes[i] == 0x0D) {
                // \n or \r
                titleEnd = i;
                break;
            }
        }

        if (titleEnd > 100) {
            titleEnd = 100;
        }

        bytes memory titleBytes = new bytes(titleEnd);
        for (uint256 i = 0; i < titleEnd; i++) {
            titleBytes[i] = descBytes[i];
        }

        return string(titleBytes);
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalVotingPeriod(uint256 proposalId) public view returns (uint256) {
        if (emergencyProposals[proposalId]) {
            return emergencyVotingPeriod;
        }
        return votingPeriod();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        uint256 totalSupply = token().getPastTotalSupply(block.number - 1);
        return totalSupply == 0 ? 0 : (totalSupply * proposalThresholdBPS) / 10000;
    }

    function emergencyProposalThreshold() public view returns (uint256) {
        uint256 totalSupply = token().getPastTotalSupply(block.number - 1);
        return totalSupply == 0 ? 0 : (totalSupply * emergencyProposalThresholdBPS) / 10000;
    }

    function updateProposalThresholds(uint256 _newProposalThresholdBPS, uint256 _newEmergencyProposalThresholdBPS)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_newProposalThresholdBPS > 10000 || _newEmergencyProposalThresholdBPS > 10000) {
            revert InvalidProposalThreshold();
        }
        if (_newEmergencyProposalThresholdBPS >= _newProposalThresholdBPS) {
            revert InvalidProposalThreshold();
        }

        uint256 oldThreshold = proposalThresholdBPS;
        uint256 oldEmergencyThreshold = emergencyProposalThresholdBPS;

        proposalThresholdBPS = _newProposalThresholdBPS;
        emergencyProposalThresholdBPS = _newEmergencyProposalThresholdBPS;

        emit ProposalThresholdUpdated(
            oldThreshold, _newProposalThresholdBPS, oldEmergencyThreshold, _newEmergencyProposalThresholdBPS
        );
    }

    function updateEmergencyVotingPeriod(uint256 _newEmergencyVotingPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newEmergencyVotingPeriod == 0 || _newEmergencyVotingPeriod >= votingPeriod()) {
            revert InvalidVotingPeriod();
        }

        uint256 oldPeriod = emergencyVotingPeriod;
        emergencyVotingPeriod = _newEmergencyVotingPeriod;

        emit EmergencyVotingPeriodUpdated(oldPeriod, _newEmergencyVotingPeriod);
    }

    function getProposalMetadata(uint256 proposalId) external view returns (ProposalMetadata memory) {
        return proposalMetadata[proposalId];
    }

    function getQuadraticResult(uint256 proposalId) external view returns (QuadraticResult memory) {
        return quadraticResults[proposalId];
    }

    function isEmergencyProposal(uint256 proposalId) external view returns (bool) {
        return emergencyProposals[proposalId];
    }

    function getProposalOptions(uint256 proposalId) external view returns (string[] memory) {
        return proposalMetadata[proposalId].options;
    }

    function emergencyPause() external onlyRole(EMERGENCY_ROLE) {
        paused = true;
        emit EmergencyPaused(msg.sender);
    }

    function emergencyUnpause() external onlyRole(EMERGENCY_ROLE) {
        paused = false;
        emit EmergencyUnpaused(msg.sender);
    }

    function supportsInterface(bytes4 interfaceId) public view override(Governor, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
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
        if (emergencyProposals[proposalId]) {
            return proposalSnapshot(proposalId) + emergencyVotingPeriod;
        }
        return super.proposalDeadline(proposalId);
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

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
