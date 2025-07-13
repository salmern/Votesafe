// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IQuadraticVoting {
    function createProposal(
        string memory title,
        string memory description,
        string[] memory options,
        uint256 duration
    ) external returns (uint256);

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
}

contract QuadraticVotingHandler {
    struct ProposalMetadata {
        uint256 createdAt;
        uint256 quadraticVotingId;
        string[] options;
        bool useQuadraticVoting;
    }

     

    struct QuadraticResult {
        uint256 quadraticProposalId;
        uint256 winningOption;
        uint256 totalVotes;
        bool processed;
    }

    address public immutable governor;
    IQuadraticVoting public immutable quadraticVoting;

    mapping(uint256 => ProposalMetadata) public proposalMetadata;
    mapping(uint256 => QuadraticResult) public quadraticResults;
    mapping(uint256 => uint256) public proposalToQuadraticId;

    event ProposalCreatedWithQuadratic(
        uint256 indexed proposalId, uint256 indexed quadraticProposalId, address indexed proposer
    );

    event QuadraticResultProcessed(
        uint256 indexed proposalId, uint256 indexed quadraticProposalId, uint256 winningOption, uint256 totalVotes
    );

    error OnlyGovernor();
    error NoQuadraticVotingForProposal();
    error ProposalAlreadyProcessed();
    error QuadraticResultNotReady();

    modifier onlyGovernor() {
        if (msg.sender != governor) revert OnlyGovernor();
        _;
    }

    constructor(address _governor, IQuadraticVoting _quadraticVoting) {
        governor = _governor;
        quadraticVoting = _quadraticVoting;
    }

    function  createQuadraticProposal(
        uint256 proposalId,
        string memory description,
        string[] memory options
    ) external onlyGovernor virtual {
        string memory title = _extractTitle(description);
        uint256 quadraticProposalId = quadraticVoting.createProposal(title, description, options, 7 days);

        proposalMetadata[proposalId] = ProposalMetadata({
            createdAt: block.timestamp,
            quadraticVotingId: quadraticProposalId,
            options: options,
            useQuadraticVoting: true
        });

        proposalToQuadraticId[proposalId] = quadraticProposalId;

        emit ProposalCreatedWithQuadratic(proposalId, quadraticProposalId, tx.origin);
    }

    function processQuadraticResults(uint256 proposalId) external onlyGovernor {
        if (proposalToQuadraticId[proposalId] == 0) {
            revert NoQuadraticVotingForProposal();
        }

        if (quadraticResults[proposalId].processed) {
            revert ProposalAlreadyProcessed();
        }

        (, , , , , uint256 endTime, , , , , ) = quadraticVoting.getProposal(proposalToQuadraticId[proposalId]);
        if (block.timestamp < endTime) {
            revert QuadraticResultNotReady();
        }

        (uint256 winningOption, uint256 totalVotes) = quadraticVoting.getWinningOption(proposalToQuadraticId[proposalId]);

        quadraticResults[proposalId] = QuadraticResult({
            quadraticProposalId: proposalToQuadraticId[proposalId],
            winningOption: winningOption,
            totalVotes: totalVotes,
            processed: true
        });

        emit QuadraticResultProcessed(proposalId, proposalToQuadraticId[proposalId], winningOption, totalVotes);
    }

    function _extractTitle(string memory description) internal pure returns (string memory) {
        bytes memory descBytes = bytes(description);
        if (descBytes.length == 0) return "Untitled Proposal";

        uint256 titleEnd = descBytes.length;
        uint256 maxLength = descBytes.length < 100 ? descBytes.length : 100;

        for (uint256 i = 0; i < maxLength; i++) {
            if (descBytes[i] == 0x0A || descBytes[i] == 0x0D) {
                titleEnd = i;
                break;
            }
        }

        bytes memory titleBytes = new bytes(titleEnd);
        for (uint256 i = 0; i < titleEnd; i++) {
            titleBytes[i] = descBytes[i];
        }

        return string(titleBytes);
    }

    function getProposalMetadata(uint256 proposalId) external view returns (ProposalMetadata memory) {
        return proposalMetadata[proposalId];
    }

    function getQuadraticResult(uint256 proposalId) external view virtual returns (QuadraticResult memory) {
        return quadraticResults[proposalId];
    }
} 
