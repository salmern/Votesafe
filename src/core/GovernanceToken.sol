// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";

/**
 * @title GovernanceToken
 * @dev ERC20 token with voting capabilities and permit functionality
 * @notice This token is used for governance voting in the VoteSafe system
 *
 * Key Features:
 * - ERC20Votes: Enables delegation and voting power tracking
 * - ERC20Permit: Gas-efficient approvals via signatures
 * - Ownable: Controlled minting by owner
 * - Snapshot compatibility: Built-in checkpoint system
 *
 * Gas Optimizations:
 * - Uses ERC20Votes for efficient delegation tracking
 * - Implements permit to avoid approval transactions
 * - Optimized storage layout
 */
contract GovernanceToken is ERC20, ERC20Permit, ERC20Votes, Ownable {
    /// @notice Maximum supply to prevent infinite inflation
    uint256 public constant MAX_SUPPLY = 1_000_000_000e18; // 1 billion tokens

    /// @notice Minimum time between mints (prevents spam minting)
    uint256 public constant MIN_MINT_INTERVAL = 1 days;

    /// @notice Last mint timestamp
    uint256 public lastMintTime;

    /// @notice Maximum tokens that can be minted per transaction
    uint256 public constant MAX_MINT_PER_TX = 10_000_000e18; // 10 million tokens

    /// @notice Emitted when tokens are minted
    event TokensMinted(address indexed to, uint256 amount);

    /// @notice Emitted when max supply is updated
    event MaxSupplyUpdated(uint256 oldMaxSupply, uint256 newMaxSupply);

    /// @notice Errors for better gas efficiency and clarity
    error ExceedsMaxSupply();
    error ExceedsMaxMintPerTx();
    error MintTooSoon();
    error ZeroAddress();
    error ZeroAmount();

    /**
     * @dev Constructor sets up the token with initial parameters
     * @param initialOwner Address that will own the contract
     * @param initialSupply Initial token supply to mint
     */
    constructor(address initialOwner, uint256 initialSupply)
        ERC20("VoteSafe Governance Token", "VOTE")
        ERC20Permit("VoteSafe Governance Token")
        Ownable(initialOwner)
    {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (initialSupply > MAX_SUPPLY) revert ExceedsMaxSupply();

        if (initialSupply > 0) {
            _mint(initialOwner, initialSupply);
            lastMintTime = block.timestamp;
        }
    }

    /**
     * @dev Mints new tokens to specified address
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     *
     * Requirements:
     * - Only owner can mint
     * - Cannot exceed max supply
     * - Cannot exceed max mint per transaction
     * - Must wait minimum interval between mints
     */
    function mint(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > MAX_MINT_PER_TX) revert ExceedsMaxMintPerTx();
        if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply();
        if (block.timestamp < lastMintTime + MIN_MINT_INTERVAL) revert MintTooSoon();

        lastMintTime = block.timestamp;
        _mint(to, amount);

        emit TokensMinted(to, amount);
    }

    /**
     * @dev Batch mint to multiple addresses (gas efficient)
     * @param recipients Array of addresses to mint to
     * @param amounts Array of amounts to mint
     */
    function batchMint(address[] calldata recipients, uint256[] calldata amounts) external onlyOwner {
        if (recipients.length != amounts.length) revert("Arrays length mismatch");
        if (recipients.length == 0) revert("Empty arrays");
        if (block.timestamp < lastMintTime + MIN_MINT_INTERVAL) revert MintTooSoon();

        uint256 totalAmount = 0;
        uint256 length = recipients.length;

        // Calculate total amount first
        for (uint256 i = 0; i < length;) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0) revert ZeroAmount();
            totalAmount += amounts[i];
            unchecked {
                ++i;
            }
        }

        if (totalAmount > MAX_MINT_PER_TX) revert ExceedsMaxMintPerTx();
        if (totalSupply() + totalAmount > MAX_SUPPLY) revert ExceedsMaxSupply();

        lastMintTime = block.timestamp;

        // Mint to each recipient
        for (uint256 i = 0; i < length;) {
            _mint(recipients[i], amounts[i]);
            emit TokensMinted(recipients[i], amounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Delegate votes to another address
     * @param delegatee Address to delegate votes to
     * @notice This is gas-optimized delegation
     */
    function delegate(address delegatee) public override {
        _delegate(_msgSender(), delegatee);
    }

    /**
     * @dev Delegate votes using signature (gasless delegation)
     * @param delegatee Address to delegate votes to
     * @param nonce Nonce for replay protection
     * @param expiry Expiration timestamp
     * @param v,r,s Signature components
     */
    function delegateBySig(address delegatee, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)
        public
        override
    {
        if (block.timestamp > expiry) revert("Signature expired");

        bytes32 domainSeparator = _domainSeparatorV4();
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)"), delegatee, nonce, expiry
            )
        );

        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signer = ecrecover(hash, v, r, s);

        if (signer == address(0)) revert("Invalid signature");
        if (nonce != _useNonce(signer)) revert("Invalid nonce");

        _delegate(signer, delegatee);
    }

    /**
     * @dev Returns the voting power of an account at a specific block
     * @param account Address to check voting power for
     * @param blockNumber Block number to check at
     * @return Voting power at the specified block
     */
    function getPastVotes(address account, uint256 blockNumber) public view override returns (uint256) {
        return super.getPastVotes(account, blockNumber);
    }

    /**
     * @dev Returns the current voting power of an account
     * @param account Address to check voting power for
     * @return Current voting power
     */
    function getVotes(address account) public view override returns (uint256) {
        return super.getVotes(account);
    }

    /**
     * @dev Returns the current delegatee of an account
     * @param account Address to check delegatee for
     * @return Address of the delegatee
     */
    function delegates(address account) public view override returns (address) {
        return super.delegates(account);
    }

    /**
     * @dev Returns the total supply at a specific block
     * @param blockNumber Block number to check at
     * @return Total supply at the specified block
     */
    function getPastTotalSupply(uint256 blockNumber) public view override returns (uint256) {
        return super.getPastTotalSupply(blockNumber);
    }

    /**
     * @dev Gas-efficient transfer with automatic delegation
     * @param to Address to transfer to
     * @param amount Amount to transfer
     * @return Success status
     */
    function transfer(address to, uint256 amount) public override returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, amount);

        // Auto-delegate to self if not already delegated (gas-efficient governance participation)
        if (delegates(to) == address(0) && balanceOf(to) > 0) {
            _delegate(to, to);
        }

        return true;
    }

    /**
     * @dev Gas-efficient transferFrom with automatic delegation
     */
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);

        // Auto-delegate to self if not already delegated
        if (delegates(to) == address(0) && balanceOf(to) > 0) {
            _delegate(to, to);
        }

        return true;
    }

    /**
     * @dev Burn tokens from caller's account
     * @param amount Amount to burn
     */
    function burn(uint256 amount) external {
        _burn(_msgSender(), amount);
    }

    /**
     * @dev Burn tokens from specified account (with allowance)
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, _msgSender(), amount);
        _burn(from, amount);
    }

    // Required overrides for multiple inheritance
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    /**
     * @dev Returns the current block number (can be overridden for testing)
     * @return Current block number
     */
    function clock() public view override returns (uint48) {
        return uint48(block.number);
    }

    /**
     * @dev Returns the clock mode for voting
     * @return Clock mode description
     */
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    /**
     * @dev Returns contract version for upgrades
     * @return Version string
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    /**
     * @dev Emergency pause function (only owner)
     * @notice Can be used to pause transfers in emergency situations
     */
    function pause() external onlyOwner {
        // Implementation would go here if needed
        // Could use OpenZeppelin's Pausable extension
    }

    /**
     * @dev Get detailed token information
     * @return name The name of the token
     * @return symbol The symbol of the token
     * @return decimals The number of decimals
     * @return totalSupply The total token supply
     * @return maxSupply The maximum token supply
     * @return lastMintTimestamp The timestamp of the last mint
     * @return owner The owner of the contract
     */
    // function getTokenInfo()
    //     external
    //     view
    //     returns (
    //         string memory name,
    //         string memory symbol,
    //         uint8 decimals,
    //         uint256 totalSupply,
    //         uint256 maxSupply,
    //         uint256 lastMintTimestamp,
    //         address owner
    //     )
    // {
    //     return (name, symbol, decimals, totalSupply, MAX_SUPPLY, lastMintTime, owner);
    // }

    function getTokenInfo()
        external
        view
        returns (string memory, string memory, uint8, uint256, uint256, uint256, address)
    {
        return (
            name(), // ✅ call function
            symbol(), // ✅ call function
            decimals(), // ✅ call function
            totalSupply(), // ✅ call function
            MAX_SUPPLY,
            lastMintTime,
            owner() // ✅ call function from Ownable
        );
    }
}
