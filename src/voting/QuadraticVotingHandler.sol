// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IQuadraticVoting {
    function createProposal(
        string memory title,
        string memory description,
        string[] memory options,
        uint256 duration
    ) external returns (uint256);

    function getProposal(
        uint256 proposalId
    )
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

    function getWinningOption(
        uint256 proposalId
    ) external view returns (uint256 winningOption, uint256 votes);
}

/**
 * @title QuadraticVotingHandler
 * @dev Handles integration between Governor and QuadraticVoting contracts
 * @notice Provides enhanced proposal metadata tracking and result processing
 *
 * Key Features:
 * - Gas-optimized title extraction from descriptions
 * - Comprehensive result processing with validation
 * - Enhanced metadata tracking for proposals
 * - Event-driven architecture for external integrations
 */
contract QuadraticVotingHandler {
    /// @notice Metadata structure for tracking proposals
    struct ProposalMetadata {
        uint256 createdAt;
        uint256 quadraticVotingId;
        string[] options;
        bool useQuadraticVoting;
    }

    /// @notice Results from quadratic voting
    struct QuadraticResult {
        uint256 quadraticProposalId;
        uint256 winningOption;
        uint256 totalVotes;
        bool processed;
    }

    /// @notice Governor contract address (immutable for gas savings)
    address public immutable governor;

    /// @notice QuadraticVoting contract interface (immutable for gas savings)
    IQuadraticVoting public immutable quadraticVoting;

    /// @notice Mapping of governor proposal ID to metadata
    mapping(uint256 => ProposalMetadata) public proposalMetadata;

    /// @notice Mapping of governor proposal ID to quadratic voting results
    mapping(uint256 => QuadraticResult) public quadraticResults;

    /// @notice Quick lookup from governor proposal to quadratic voting ID
    mapping(uint256 => uint256) public proposalToQuadraticId;

    /// @notice Events for external monitoring and integration
    event ProposalCreatedWithQuadratic(
        uint256 indexed proposalId,
        uint256 indexed quadraticProposalId,
        address indexed proposer
    );

    event QuadraticResultProcessed(
        uint256 indexed proposalId,
        uint256 indexed quadraticProposalId,
        uint256 winningOption,
        uint256 totalVotes
    );

    /// @notice Custom errors for gas efficiency
    error OnlyGovernor();
    error NoQuadraticVotingForProposal();
    error ProposalAlreadyProcessed();
    error QuadraticResultNotReady();
    error InvalidProposalData();

    /// @notice Ensures only governor can call certain functions
    modifier onlyGovernor() {
        if (msg.sender != governor) revert OnlyGovernor();
        _;
    }

    /**
     * @dev Constructor
     * @param _governor Address of the governor contract
     * @param _quadraticVoting Address of the quadratic voting contract
     */
    constructor(address _governor, IQuadraticVoting _quadraticVoting) {
        governor = _governor;
        quadraticVoting = _quadraticVoting;
    }

    /**
     * @dev Create a quadratic voting proposal linked to a governor proposal
     * @param proposalId Governor proposal ID
     * @param description Proposal description
     * @param options Array of voting options
     */
    function createQuadraticProposal(
        uint256 proposalId,
        string memory description,
        string[] memory options
    ) external virtual onlyGovernor {
        // Validate input parameters
        if (bytes(description).length == 0) revert InvalidProposalData();
        if (options.length < 2) revert InvalidProposalData();
        if (options.length > 10) revert InvalidProposalData();

        // Extract title using gas-optimized method
        string memory title = _extractTitle(description);

        // Create quadratic voting proposal (7 days duration)
        uint256 quadraticProposalId = quadraticVoting.createProposal(
            title,
            description,
            options,
            7 days
        );

        // Store metadata with gas-optimized struct packing
        proposalMetadata[proposalId] = ProposalMetadata({
            createdAt: block.timestamp,
            quadraticVotingId: quadraticProposalId,
            options: options,
            useQuadraticVoting: true
        });

        // Store quick lookup mapping
        proposalToQuadraticId[proposalId] = quadraticProposalId;

        emit ProposalCreatedWithQuadratic(
            proposalId,
            quadraticProposalId,
            tx.origin // Original proposer (through governor)
        );
    }

    /**
     * @dev Process quadratic voting results after voting period ends
     * @param proposalId Governor proposal ID
     */
    function processQuadraticResults(uint256 proposalId) external onlyGovernor {
        // Check if quadratic voting exists for this proposal
        uint256 quadraticProposalId = proposalToQuadraticId[proposalId];
        if (quadraticProposalId == 0) {
            revert NoQuadraticVotingForProposal();
        }

        // Prevent double processing
        if (quadraticResults[proposalId].processed) {
            revert ProposalAlreadyProcessed();
        }

        // Get proposal details to check if voting period has ended
        (, , , , , uint256 endTime, , , , , ) = quadraticVoting.getProposal(
            quadraticProposalId
        );

        if (block.timestamp < endTime) {
            revert QuadraticResultNotReady();
        }

        // Get winning option and total votes
        (uint256 winningOption, uint256 totalVotes) = quadraticVoting
            .getWinningOption(quadraticProposalId);

        // Store results
        quadraticResults[proposalId] = QuadraticResult({
            quadraticProposalId: quadraticProposalId,
            winningOption: winningOption,
            totalVotes: totalVotes,
            processed: true
        });

        emit QuadraticResultProcessed(
            proposalId,
            quadraticProposalId,
            winningOption,
            totalVotes
        );
    }

    /**
     * @dev Gas-optimized title extraction from proposal description
     * @param description Full proposal description
     * @return Extracted title (first line or first 100 chars)
     *
     * Gas Optimizations:
     * - Uses assembly for efficient byte operations
     * - Minimizes memory allocations
     * - Early break on newline detection
     */
    function _extractTitle(
        string memory description
    ) internal pure returns (string memory) {
        bytes memory descBytes = bytes(description);
        if (descBytes.length == 0) return "Untitled Proposal";

        uint256 end = descBytes.length > 100 ? 100 : descBytes.length;

        // Gas-optimized assembly version for finding newlines
        assembly {
            let dataPtr := add(descBytes, 0x20)
            for {
                let i := 0
            } lt(i, end) {
                i := add(i, 1)
            } {
                let b := byte(0, mload(add(dataPtr, i)))
                // Check for newline (0x0A) or carriage return (0x0D)
                if or(eq(b, 0x0A), eq(b, 0x0D)) {
                    end := i
                    break
                }
            }
        }

        // Create title bytes array
        bytes memory titleBytes = new bytes(end);

        // Copy bytes efficiently
        assembly {
            let src := add(descBytes, 0x20)
            let dst := add(titleBytes, 0x20)

            // Copy in 32-byte chunks when possible
            let chunks := div(end, 32)
            for {
                let i := 0
            } lt(i, chunks) {
                i := add(i, 1)
            } {
                let offset := mul(i, 32)
                mstore(add(dst, offset), mload(add(src, offset)))
            }

            // Copy remaining bytes
            let remaining := mod(end, 32)
            if remaining {
                let lastChunkOffset := mul(chunks, 32)
                let mask := sub(shl(mul(remaining, 8), 1), 1)
                let srcData := and(mload(add(src, lastChunkOffset)), mask)
                mstore(add(dst, lastChunkOffset), srcData)
            }
        }

        return string(titleBytes);
    }

    /**
     * @dev Get proposal metadata for a given proposal ID
     * @param proposalId Governor proposal ID
     * @return ProposalMetadata struct
     */
    function getProposalMetadata(
        uint256 proposalId
    ) external view returns (ProposalMetadata memory) {
        return proposalMetadata[proposalId];
    }

    /**
     * @dev Get quadratic voting results for a given proposal ID
     * @param proposalId Governor proposal ID
     * @return QuadraticResult struct
     */
    function getQuadraticResult(
        uint256 proposalId
    ) external view virtual returns (QuadraticResult memory) {
        return quadraticResults[proposalId];
    }

    /**
     * @dev Check if a proposal has associated quadratic voting
     * @param proposalId Governor proposal ID
     * @return bool indicating if quadratic voting exists
     */
    function hasQuadraticVoting(
        uint256 proposalId
    ) external view returns (bool) {
        return proposalToQuadraticId[proposalId] != 0;
    }

    /**
     * @dev Get quadratic voting ID for a governor proposal
     * @param proposalId Governor proposal ID
     * @return Quadratic voting proposal ID (0 if none exists)
     */
    function getQuadraticVotingId(
        uint256 proposalId
    ) external view returns (uint256) {
        return proposalToQuadraticId[proposalId];
    }

    /**
     * @dev Check if quadratic voting results are ready to be processed
     * @param proposalId Governor proposal ID
     * @return bool indicating if results are ready
     */
    function isQuadraticVotingComplete(
        uint256 proposalId
    ) external view returns (bool) {
        uint256 quadraticProposalId = proposalToQuadraticId[proposalId];
        if (quadraticProposalId == 0) return false;

        (, , , , , uint256 endTime, , , , , ) = quadraticVoting.getProposal(
            quadraticProposalId
        );

        return block.timestamp >= endTime;
    }

    /**
     * @dev Batch process multiple quadratic voting results
     * @param proposalIds Array of governor proposal IDs
     * @return processedCount Number of results successfully processed
     */
    function batchProcessQuadraticResults(
        uint256[] memory proposalIds
    ) external onlyGovernor returns (uint256 processedCount) {
        for (uint256 i = 0; i < proposalIds.length; ) {
            uint256 proposalId = proposalIds[i];

            // Skip if no quadratic voting or already processed
            if (
                proposalToQuadraticId[proposalId] == 0 ||
                quadraticResults[proposalId].processed
            ) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // Check if voting period has ended
            (, , , , , uint256 endTime, , , , , ) = quadraticVoting.getProposal(
                proposalToQuadraticId[proposalId]
            );

            if (block.timestamp < endTime) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // Process results
            (uint256 winningOption, uint256 totalVotes) = quadraticVoting
                .getWinningOption(proposalToQuadraticId[proposalId]);

            quadraticResults[proposalId] = QuadraticResult({
                quadraticProposalId: proposalToQuadraticId[proposalId],
                winningOption: winningOption,
                totalVotes: totalVotes,
                processed: true
            });

            emit QuadraticResultProcessed(
                proposalId,
                proposalToQuadraticId[proposalId],
                winningOption,
                totalVotes
            );

            unchecked {
                ++processedCount;
                ++i;
            }
        }
    }
}
