// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "src/voting/QuadraticVotingHandler.sol";

contract MockQuadraticVotingHandler is QuadraticVotingHandler {
    constructor(address _governor) QuadraticVotingHandler(_governor, IQuadraticVoting(address(0))) {}

    // This is the function the governor actually calls
    function createQuadraticProposal(uint256 proposalId, string memory, /* description */ string[] memory options)
        external
        override
    {
        // Store the proposal metadata
        proposalMetadata[proposalId] = ProposalMetadata({
            createdAt: block.timestamp,
            quadraticVotingId: proposalId + 1000, // Mock QV ID
            options: options,
            useQuadraticVoting: true
        });

        // Map the proposal to quadratic ID
        proposalToQuadraticId[proposalId] = proposalId + 1000;

        emit ProposalCreatedWithQuadratic(proposalId, proposalMetadata[proposalId].quadraticVotingId, msg.sender);
    }

    //mock function to simulate proposal creation
    function mockCreateProposal(uint256 proposalId, string[] memory options) external {
        proposalMetadata[proposalId] = ProposalMetadata({
            createdAt: block.timestamp,
            quadraticVotingId: proposalId + 1000,
            options: options,
            useQuadraticVoting: true
        });

        proposalToQuadraticId[proposalId] = proposalId + 1000;
    }

    function mockSetResult(uint256 proposalId, uint256 winningOption, uint256 totalVotes) external {
        quadraticResults[proposalId] = QuadraticResult({
            quadraticProposalId: proposalToQuadraticId[proposalId],
            winningOption: winningOption,
            totalVotes: totalVotes,
            processed: true
        });
    }

    function getProposalOptions(uint256 proposalId) external view returns (string[] memory) {
        return proposalMetadata[proposalId].options;
    }

    // Mock implementation for any other required functions from parent
    function getQuadraticResult(uint256 proposalId) external view override returns (QuadraticResult memory) {
        return quadraticResults[proposalId];
    }
}
