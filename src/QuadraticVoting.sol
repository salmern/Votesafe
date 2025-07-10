// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title QuadraticVoting
 * @dev Implements quadratic voting mechanism with Sybil attack prevention
 * @notice Voting power = sqrt(tokens allocated) to reduce whale influence
 * 
 * Key Features:
 * - Quadratic voting: votes = sqrt(tokens used)
 * - Sybil attack prevention through token requirements
 * - Snapshot.js compatibility for off-chain voting
 * - Gas-optimized batch operations
 * - Role-based access control
 * 
 * Security Features:
 * - Minimum token threshold for participation
 * - Maximum voting power per address
 * - Time-locked token commitment
 * - Signature-based off-chain voting
 */
contract QuadraticVoting is AccessControl, ReentrancyGuard, Pausable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    
    /// @notice Role identifiers
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    
    /// @notice Governance token interface
    IERC20 public immutable governanceToken;
    
    /// @notice Minimum tokens required to participate (Sybil protection)
    uint256 public minTokensRequired;
    
    /// @notice Maximum tokens that can be allocated per vote (whale protection)
    uint256 public maxTokensPerVote;
    
    /// @notice Time lock for token commitments (prevents flash loan attacks)
    uint256 public constant TOKEN_LOCK_PERIOD = 1 hours;
    
    /// @notice Proposal counter
    uint256 public proposalCount;
    
    /// @notice Voting proposal structure
    struct Proposal {
        uint256 id;
        string title;
        string description;
        address proposer;
        uint256 startTime;
        uint256 endTime;
        uint256 totalTokensAllocated;
        uint256 totalVotingPower;
        uint256[] optionVotes; // Array of votes for each option
        mapping(address => UserVote) userVotes;
        mapping(address => uint256) tokenCommitments;
        mapping(address => uint256) commitmentTimestamp;
        string[] options;
        bool executed;
        bytes32 snapshotHash; // For off-chain voting verification
    }
    
    /// @notice User vote structure
    struct UserVote {
        uint256 tokensAllocated;
        uint256 votingPower;
        uint256[] optionWeights; // Weights for each option (must sum to 100)
        uint256 timestamp;
        bool hasVoted;
    }
    
    /// @notice Token commitment structure
    struct TokenCommitment {
        uint256 amount;
        uint256 timestamp;
        uint256 proposalId;
    }
    
    /// @notice Mapping of proposals
    mapping(uint256 => Proposal) public proposals;
    
    /// @notice Mapping of user token commitments
    mapping(address => mapping(uint256 => TokenCommitment)) public tokenCommitments;
    
    /// @notice Mapping of used signatures for off-chain voting
    mapping(bytes32 => bool) public usedSignatures;
    
    /// @notice Events
    event ProposalCreated(
        uint256 indexed proposalId,
        string title,
        address indexed proposer,
        uint256 startTime,
        uint256 endTime,
        string[] options
    );
    
    event TokensCommitted(
        uint256 indexed proposalId,
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );
    
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        uint256 tokensAllocated,
        uint256 votingPower,
        uint256[] optionWeights
    );
    
    event OffChainVoteVerified(
        uint256 indexed proposalId,
        bytes32 snapshotHash,
        uint256 totalVotes
    );
    
    event TokensWithdrawn(
        uint256 indexed proposalId,
        address indexed user,
        uint256 amount
    );
    
    event ProposalExecuted(
        uint256 indexed proposalId,
        uint256 winningOption,
        uint256 totalVotes
    );
    
    event ParametersUpdated(
        uint256 oldMinTokens,
        uint256 newMinTokens,
        uint256 oldMaxTokens,
        uint256 newMaxTokens
    );
    
    /// @notice Custom errors
    error InvalidProposal();
    error ProposalNotActive();
    error ProposalEnded();
    error InsufficientTokens();
    error TokensNotUnlocked();
    error InvalidVoteWeights();
    error AlreadyVoted();
    error NotEnoughTokensCommitted();
    error InvalidSignature();
    error SignatureAlreadyUsed();
    error InvalidOptionWeights();
    error ExceedsMaxTokensPerVote();
    error BelowMinTokensRequired();
    error ProposalAlreadyExecuted();
    error VotingStillActive();
    error ZeroAddress();
    error InvalidDuration();
    error InvalidParameters();
    
    /**
     * @dev Constructor
     * @param _governanceToken Address of the governance token
     * @param _minTokensRequired Minimum tokens required to participate
     * @param _maxTokensPerVote Maximum tokens per vote
     */
    constructor(
        address _governanceToken,
        uint256 _minTokensRequired,
        uint256 _maxTokensPerVote
    ) {
        if (_governanceToken == address(0)) revert ZeroAddress();
        if (_minTokensRequired == 0) revert InvalidParameters();
        if (_maxTokensPerVote <= _minTokensRequired) revert InvalidParameters();
        
        governanceToken = IERC20(_governanceToken);
        minTokensRequired = _minTokensRequired;
        maxTokensPerVote = _maxTokensPerVote;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }
    
    /**
     * @dev Create a new voting proposal
     * @param title Proposal title
     * @param description Proposal description
     * @param options Array of voting options
     * @param duration Voting duration in seconds
     */
    function createProposal(
        string memory title,
        string memory description,
        string[] memory options,
        uint256 duration
    ) external onlyRole(PROPOSER_ROLE) {
        if (bytes(title).length == 0) revert InvalidParameters();
        if (options.length < 2) revert InvalidParameters();
        if (options.length > 10) revert InvalidParameters();
        if (duration < 1 hours) revert InvalidDuration();
        if (duration > 30 days) revert InvalidDuration();
        
        uint256 proposalId = proposalCount++;
        Proposal storage proposal = proposals[proposalId];
        
        proposal.id = proposalId;
        proposal.title = title;
        proposal.description = description;
        proposal.proposer = msg.sender;
        proposal.startTime = block.timestamp;
        proposal.endTime = block.timestamp + duration;
        proposal.options = options;
        proposal.optionVotes = new uint256[](options.length);
        
        emit ProposalCreated(
            proposalId,
            title,
            msg.sender,
            proposal.startTime,
            proposal.endTime,
            options
        );
    }
    
    /**
     * @dev Commit tokens for voting (must be done before voting)
     * @param proposalId Proposal ID
     * @param amount Amount of tokens to commit
     */
    function commitTokens(uint256 proposalId, uint256 amount) external nonReentrant {
        if (proposalId >= proposalCount) revert InvalidProposal();
        if (amount < minTokensRequired) revert BelowMinTokensRequired();
        if (amount > maxTokensPerVote) revert ExceedsMaxTokensPerVote();
        
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp >= proposal.endTime) revert ProposalEnded();
        
        // Check user has enough tokens
        if (governanceToken.balanceOf(msg.sender) < amount) revert InsufficientTokens();
        
        // Transfer tokens to this contract
        governanceToken.transferFrom(msg.sender, address(this), amount);
        
        // Record commitment
        tokenCommitments[msg.sender][proposalId] = TokenCommitment({
            amount: amount,
            timestamp: block.timestamp,
            proposalId: proposalId
        });
        
        proposal.tokenCommitments[msg.sender] = amount;
        proposal.commitmentTimestamp[msg.sender] = block.timestamp;
        
        emit TokensCommitted(proposalId, msg.sender, amount, block.timestamp);
    }
    
    /**
     * @dev Cast quadratic vote
     * @param proposalId Proposal ID
     * @param tokensToAllocate Tokens to allocate for voting
     * @param optionWeights Array of weights for each option (must sum to 100)
     */
    function vote(
        uint256 proposalId,
        uint256 tokensToAllocate,
        uint256[] memory optionWeights
    ) external nonReentrant whenNotPaused {
        if (proposalId >= proposalCount) revert InvalidProposal();
        
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp < proposal.startTime || block.timestamp >= proposal.endTime) {
            revert ProposalNotActive();
        }
        
        if (proposal.userVotes[msg.sender].hasVoted) revert AlreadyVoted();
        
        // Check token commitment
        uint256 committedTokens = proposal.tokenCommitments[msg.sender];
        if (committedTokens < tokensToAllocate) revert NotEnoughTokensCommitted();
        
        // Check time lock
        if (block.timestamp < proposal.commitmentTimestamp[msg.sender] + TOKEN_LOCK_PERIOD) {
            revert TokensNotUnlocked();
        }
        
        // Validate option weights
        if (optionWeights.length != proposal.options.length) revert InvalidOptionWeights();
        
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < optionWeights.length; i++) {
            totalWeight += optionWeights[i];
        }
        if (totalWeight != 100) revert InvalidVoteWeights();
        
        // Calculate quadratic voting power
        uint256 votingPower = _sqrt(tokensToAllocate);
        
        // Record vote
        proposal.userVotes[msg.sender] = UserVote({
            tokensAllocated: tokensToAllocate,
            votingPower: votingPower,
            optionWeights: optionWeights,
            timestamp: block.timestamp,
            hasVoted: true
        });
        
        // Update proposal totals
        proposal.totalTokensAllocated += tokensToAllocate;
        proposal.totalVotingPower += votingPower;
        
        // Distribute voting power across options
        for (uint256 i = 0; i < optionWeights.length; i++) {
            if (optionWeights[i] > 0) {
                proposal.optionVotes[i] += (votingPower * optionWeights[i]) / 100;
            }
        }
        
        emit VoteCast(proposalId, msg.sender, tokensToAllocate, votingPower, optionWeights);
    }
    
    /**
     * @dev Verify off-chain vote using signature
     * @param proposalId Proposal ID
     * @param voter Voter address
     * @param tokensToAllocate Tokens allocated
     * @param optionWeights Option weights
     * @param signature Voter's signature
     */
    function verifyOffChainVote(
        uint256 proposalId,
        address voter,
        uint256 tokensToAllocate,
        uint256[] memory optionWeights,
        bytes memory signature
    ) external onlyRole(VALIDATOR_ROLE) {
        if (proposalId >= proposalCount) revert InvalidProposal();
        
        // Verify signature
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                proposalId,
                voter,
                tokensToAllocate,
                optionWeights,
                block.chainid
            )
        );
        
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        if (ethSignedMessageHash.recover(signature) != voter) revert InvalidSignature();
        
        bytes32 signatureHash = keccak256(signature);
        if (usedSignatures[signatureHash]) revert SignatureAlreadyUsed();
        usedSignatures[signatureHash] = true;
        
        // Process the vote (similar to regular vote but without token transfer)
        _processVote(proposalId, voter, tokensToAllocate, optionWeights);
    }
    
    /**
     * @dev Internal function to process votes
     */
    function _processVote(
        uint256 proposalId,
        address voter,
        uint256 tokensToAllocate,
        uint256[] memory optionWeights
    ) internal {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.userVotes[voter].hasVoted) revert AlreadyVoted();
        
        // Validate option weights
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < optionWeights.length; i++) {
            totalWeight += optionWeights[i];
        }
        if (totalWeight != 100) revert InvalidVoteWeights();
        
        // Calculate quadratic voting power
        uint256 votingPower = _sqrt(tokensToAllocate);
        
        // Record vote
        proposal.userVotes[voter] = UserVote({
            tokensAllocated: tokensToAllocate,
            votingPower: votingPower,
            optionWeights: optionWeights,
            timestamp: block.timestamp,
            hasVoted: true
        });
        
        // Update proposal totals
        proposal.totalTokensAllocated += tokensToAllocate;
        proposal.totalVotingPower += votingPower;
        
        // Distribute voting power across options
        for (uint256 i = 0; i < optionWeights.length; i++) {
            if (optionWeights[i] > 0) {
                proposal.optionVotes[i] += (votingPower * optionWeights[i]) / 100;
            }
        }
        
        emit VoteCast(proposalId, voter, tokensToAllocate, votingPower, optionWeights);
    }
    
    /**
     * @dev Execute a proposal after voting period ends
     * @param proposalId Proposal ID
     */
    function executeProposal(uint256 proposalId) external {
        if (proposalId >= proposalCount) revert InvalidProposal();
        
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp < proposal.endTime) revert VotingStillActive();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        
        // Find winning option
        uint256 winningOption = 0;
        uint256 maxVotes = proposal.optionVotes[0];
        
        for (uint256 i = 1; i < proposal.optionVotes.length; i++) {
            if (proposal.optionVotes[i] > maxVotes) {
                maxVotes = proposal.optionVotes[i];
                winningOption = i;
            }
        }
        
        proposal.executed = true;
        
        emit ProposalExecuted(proposalId, winningOption, proposal.totalVotingPower);
    }
    
    /**
     * @dev Withdraw committed tokens after voting period
     * @param proposalId Proposal ID
     */
    function withdrawTokens(uint256 proposalId) external nonReentrant {
        if (proposalId >= proposalCount) revert InvalidProposal();
        
        Proposal storage proposal = proposals[proposalId];
        if (block.timestamp < proposal.endTime) revert VotingStillActive();
        
        uint256 committedAmount = proposal.tokenCommitments[msg.sender];
        if (committedAmount == 0) revert InsufficientTokens();
        
        // Clear commitment
        proposal.tokenCommitments[msg.sender] = 0;
        delete tokenCommitments[msg.sender][proposalId];
        
        // Transfer tokens back
        governanceToken.transfer(msg.sender, committedAmount);
        
        emit TokensWithdrawn(proposalId, msg.sender, committedAmount);
    }
    
    /**
     * @dev Batch withdraw tokens from multiple proposals
     * @param proposalIds Array of proposal IDs
     */
    function batchWithdrawTokens(uint256[] memory proposalIds) external nonReentrant {
        uint256 totalWithdraw = 0;
        
        for (uint256 i = 0; i < proposalIds.length; i++) {
            uint256 proposalId = proposalIds[i];
            if (proposalId >= proposalCount) continue;
            
            Proposal storage proposal = proposals[proposalId];
            if (block.timestamp < proposal.endTime) continue;
            
            uint256 committedAmount = proposal.tokenCommitments[msg.sender];
            if (committedAmount == 0) continue;
            
            // Clear commitment
            proposal.tokenCommitments[msg.sender] = 0;
            delete tokenCommitments[msg.sender][proposalId];
            
            totalWithdraw += committedAmount;
            emit TokensWithdrawn(proposalId, msg.sender, committedAmount);
        }
        
        if (totalWithdraw > 0) {
            governanceToken.transfer(msg.sender, totalWithdraw);
        }
    }
    
    /**
     * @dev Get proposal details
     */
    function getProposal(uint256 proposalId) external view returns (
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
    ) {
        if (proposalId >= proposalCount) revert InvalidProposal();
        
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.id,
            proposal.title,
            proposal.description,
            proposal.proposer,
            proposal.startTime,
            proposal.endTime,
            proposal.totalTokensAllocated,
            proposal.totalVotingPower,
            proposal.options,
            proposal.optionVotes,
            proposal.executed
        );
    }
    
    /**
     * @dev Get user vote details
     */
    function getUserVote(uint256 proposalId, address user) external view returns (
        uint256 tokensAllocated,
        uint256 votingPower,
        uint256[] memory optionWeights,
        uint256 timestamp,
        bool hasVoted
    ) {
        if (proposalId >= proposalCount) revert InvalidProposal();
        
        UserVote storage userVote = proposals[proposalId].userVotes[user];
        return (
            userVote.tokensAllocated,
            userVote.votingPower,
            userVote.optionWeights,
            userVote.timestamp,
            userVote.hasVoted
        );
    }
    
    /**
     * @dev Get winning option for a proposal
     */
    function getWinningOption(uint256 proposalId) external view returns (uint256 winningOption, uint256 votes) {
        if (proposalId >= proposalCount) revert InvalidProposal();
        
        Proposal storage proposal = proposals[proposalId];
        
        winningOption = 0;
        votes = proposal.optionVotes[0];
        
        for (uint256 i = 1; i < proposal.optionVotes.length; i++) {
            if (proposal.optionVotes[i] > votes) {
                votes = proposal.optionVotes[i];
                winningOption = i;
            }
        }
    }
    
    /**
     * @dev Get user's token commitment for a proposal
     */
    function getUserTokenCommitment(uint256 proposalId, address user) external view returns (uint256) {
        if (proposalId >= proposalCount) revert InvalidProposal();
        return proposals[proposalId].tokenCommitments[user];
    }
    
    /**
     * @dev Check if user can vote (has committed tokens and time lock passed)
     */
    function canUserVote(uint256 proposalId, address user) external view returns (bool) {
        if (proposalId >= proposalCount) return false;
        
        Proposal storage proposal = proposals[proposalId];
        
        // Check if proposal is active
        if (block.timestamp < proposal.startTime || block.timestamp >= proposal.endTime) {
            return false;
        }
        
        // Check if user already voted
        if (proposal.userVotes[user].hasVoted) return false;
        
        // Check if user has committed tokens
        if (proposal.tokenCommitments[user] == 0) return false;
        
        // Check time lock
        if (block.timestamp < proposal.commitmentTimestamp[user] + TOKEN_LOCK_PERIOD) {
            return false;
        }
        
        return true;
    }
    
    /**
     * @dev Calculate quadratic voting power
     * @param tokens Number of tokens
     * @return Quadratic voting power (sqrt of tokens)
     */
    function calculateVotingPower(uint256 tokens) external pure returns (uint256) {
        return _sqrt(tokens);
    }
    
    /**
     * @dev Update voting parameters (admin only)
     * @param newMinTokens New minimum tokens required
     * @param newMaxTokens New maximum tokens per vote
     */
    function updateVotingParameters(
        uint256 newMinTokens,
        uint256 newMaxTokens
    ) external onlyRole(ADMIN_ROLE) {
        if (newMinTokens == 0) revert InvalidParameters();
        if (newMaxTokens <= newMinTokens) revert InvalidParameters();
        
        uint256 oldMinTokens = minTokensRequired;
        uint256 oldMaxTokens = maxTokensPerVote;
        
        minTokensRequired = newMinTokens;
        maxTokensPerVote = newMaxTokens;
        
        emit ParametersUpdated(oldMinTokens, newMinTokens, oldMaxTokens, newMaxTokens);
    }
    
    /**
     * @dev Emergency pause function
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause function
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @dev Internal square root function (gas optimized)
     * Uses Babylonian method for efficient square root calculation
     */
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        
        // Initial approximation using bit length
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        
        // Babylonian method iteration
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        
        return y;
    }
    
    /**
     * @dev Get total number of proposals
     */
    function getTotalProposals() external view returns (uint256) {
        return proposalCount;
    }
    
    /**
     * @dev Get governance token information
     */
    function getGovernanceTokenInfo() external view returns (
        address tokenAddress,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) {
        tokenAddress = address(governanceToken);
        
        // Try to get token metadata (may fail for non-standard tokens)
        try IERC20Metadata(tokenAddress).name() returns (string memory _name) {
            name = _name;
        } catch {
            name = "Unknown";
        }
        
        try IERC20Metadata(tokenAddress).symbol() returns (string memory _symbol) {
            symbol = _symbol;
        } catch {
            symbol = "UNK";
        }
        
        try IERC20Metadata(tokenAddress).decimals() returns (uint8 _decimals) {
            decimals = _decimals;
        } catch {
            decimals = 18;
        }
    }
}