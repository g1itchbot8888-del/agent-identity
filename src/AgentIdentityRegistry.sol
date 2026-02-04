// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AgentIdentityRegistry
 * @notice On-chain identity registry for AI agents
 * @dev Agents stake USDC to register, can link platforms, and verify signatures
 */
contract AgentIdentityRegistry is Ownable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // USDC on Base Sepolia
    IERC20 public immutable usdc;
    
    // Minimum stake to register (prevents spam)
    uint256 public minStake = 1e6; // 1 USDC (6 decimals)
    
    // Cooldown before stake can be withdrawn after deactivation
    uint256 public deactivationCooldown = 7 days;

    struct AgentIdentity {
        address owner;              // Wallet controlling this identity
        address signingKey;         // Separate key for signing (can be same as owner)
        string name;                // Human-readable agent name
        string metadataUri;         // IPFS URI to extended metadata
        uint256 stakedAmount;       // USDC staked
        uint256 registeredAt;       // Registration timestamp
        uint256 deactivatedAt;      // 0 if active, timestamp if deactivating
        uint256 totalVouchesReceived; // Total USDC vouched for this agent
    }

    struct Vouch {
        address voucher;
        uint256 amount;
        uint256 timestamp;
    }

    // Identity hash => AgentIdentity
    mapping(bytes32 => AgentIdentity) public identities;
    
    // Owner address => identity hash (one identity per wallet)
    mapping(address => bytes32) public ownerToIdentity;
    
    // Identity hash => platform strings (e.g., "moltbook:g1itchbot")
    mapping(bytes32 => string[]) public linkedPlatforms;
    
    // Identity hash => vouches received
    mapping(bytes32 => Vouch[]) public vouches;
    
    // Voucher => identity hash => vouch index (for withdrawing)
    mapping(address => mapping(bytes32 => uint256)) public vouchIndex;

    // Events
    event IdentityRegistered(bytes32 indexed identityHash, address indexed owner, string name, uint256 stake);
    event PlatformLinked(bytes32 indexed identityHash, string platform);
    event VouchAdded(bytes32 indexed identityHash, address indexed voucher, uint256 amount);
    event VouchWithdrawn(bytes32 indexed identityHash, address indexed voucher, uint256 amount);
    event IdentityDeactivated(bytes32 indexed identityHash);
    event IdentityReactivated(bytes32 indexed identityHash);
    event StakeWithdrawn(bytes32 indexed identityHash, uint256 amount);
    event SigningKeyUpdated(bytes32 indexed identityHash, address newKey);

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
    }

    /**
     * @notice Register a new agent identity
     * @param name Human-readable agent name
     * @param metadataUri IPFS URI to extended metadata
     * @param signingKey Address used for signing (can be same as msg.sender)
     * @param stakeAmount Amount of USDC to stake (must be >= minStake)
     */
    function register(
        string calldata name,
        string calldata metadataUri,
        address signingKey,
        uint256 stakeAmount
    ) external returns (bytes32 identityHash) {
        require(ownerToIdentity[msg.sender] == bytes32(0), "Already registered");
        require(stakeAmount >= minStake, "Stake too low");
        require(bytes(name).length > 0, "Name required");
        require(signingKey != address(0), "Invalid signing key");
        
        // Transfer USDC stake
        require(usdc.transferFrom(msg.sender, address(this), stakeAmount), "Stake transfer failed");
        
        // Generate identity hash from name + owner + timestamp
        identityHash = keccak256(abi.encodePacked(name, msg.sender, block.timestamp));
        
        identities[identityHash] = AgentIdentity({
            owner: msg.sender,
            signingKey: signingKey,
            name: name,
            metadataUri: metadataUri,
            stakedAmount: stakeAmount,
            registeredAt: block.timestamp,
            deactivatedAt: 0,
            totalVouchesReceived: 0
        });
        
        ownerToIdentity[msg.sender] = identityHash;
        
        emit IdentityRegistered(identityHash, msg.sender, name, stakeAmount);
        return identityHash;
    }

    /**
     * @notice Link a platform account to your identity
     * @param platform Platform identifier (e.g., "moltbook:g1itchbot")
     */
    function linkPlatform(string calldata platform) external {
        bytes32 identityHash = ownerToIdentity[msg.sender];
        require(identityHash != bytes32(0), "Not registered");
        require(identities[identityHash].deactivatedAt == 0, "Identity deactivated");
        
        linkedPlatforms[identityHash].push(platform);
        
        emit PlatformLinked(identityHash, platform);
    }

    /**
     * @notice Vouch for another agent by staking USDC
     * @param identityHash Identity to vouch for
     * @param amount USDC amount to stake as vouch
     */
    function vouch(bytes32 identityHash, uint256 amount) external {
        require(identities[identityHash].owner != address(0), "Identity not found");
        require(identities[identityHash].deactivatedAt == 0, "Identity deactivated");
        require(amount > 0, "Amount must be > 0");
        require(vouchIndex[msg.sender][identityHash] == 0, "Already vouched");
        
        require(usdc.transferFrom(msg.sender, address(this), amount), "Vouch transfer failed");
        
        vouches[identityHash].push(Vouch({
            voucher: msg.sender,
            amount: amount,
            timestamp: block.timestamp
        }));
        
        vouchIndex[msg.sender][identityHash] = vouches[identityHash].length; // 1-indexed
        identities[identityHash].totalVouchesReceived += amount;
        
        emit VouchAdded(identityHash, msg.sender, amount);
    }

    /**
     * @notice Withdraw your vouch for an agent
     * @param identityHash Identity to withdraw vouch from
     */
    function withdrawVouch(bytes32 identityHash) external {
        uint256 idx = vouchIndex[msg.sender][identityHash];
        require(idx > 0, "No vouch found");
        
        Vouch storage v = vouches[identityHash][idx - 1];
        uint256 amount = v.amount;
        
        // Clear vouch
        v.amount = 0;
        vouchIndex[msg.sender][identityHash] = 0;
        identities[identityHash].totalVouchesReceived -= amount;
        
        require(usdc.transfer(msg.sender, amount), "Withdraw failed");
        
        emit VouchWithdrawn(identityHash, msg.sender, amount);
    }

    /**
     * @notice Verify a signature was made by an agent's signing key
     * @param identityHash Identity claiming to have signed
     * @param messageHash Hash of the message that was signed
     * @param signature The signature to verify
     */
    function verifySignature(
        bytes32 identityHash,
        bytes32 messageHash,
        bytes calldata signature
    ) external view returns (bool) {
        AgentIdentity storage identity = identities[identityHash];
        require(identity.owner != address(0), "Identity not found");
        
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        address recovered = ethSignedHash.recover(signature);
        
        return recovered == identity.signingKey;
    }

    /**
     * @notice Update your signing key
     * @param newSigningKey New address to use for signing
     */
    function updateSigningKey(address newSigningKey) external {
        bytes32 identityHash = ownerToIdentity[msg.sender];
        require(identityHash != bytes32(0), "Not registered");
        require(newSigningKey != address(0), "Invalid signing key");
        
        identities[identityHash].signingKey = newSigningKey;
        
        emit SigningKeyUpdated(identityHash, newSigningKey);
    }

    /**
     * @notice Start deactivation process (begins cooldown)
     */
    function deactivate() external {
        bytes32 identityHash = ownerToIdentity[msg.sender];
        require(identityHash != bytes32(0), "Not registered");
        require(identities[identityHash].deactivatedAt == 0, "Already deactivating");
        
        identities[identityHash].deactivatedAt = block.timestamp;
        
        emit IdentityDeactivated(identityHash);
    }

    /**
     * @notice Cancel deactivation and reactivate identity
     */
    function reactivate() external {
        bytes32 identityHash = ownerToIdentity[msg.sender];
        require(identityHash != bytes32(0), "Not registered");
        require(identities[identityHash].deactivatedAt > 0, "Not deactivating");
        
        identities[identityHash].deactivatedAt = 0;
        
        emit IdentityReactivated(identityHash);
    }

    /**
     * @notice Withdraw stake after deactivation cooldown
     */
    function withdrawStake() external {
        bytes32 identityHash = ownerToIdentity[msg.sender];
        require(identityHash != bytes32(0), "Not registered");
        
        AgentIdentity storage identity = identities[identityHash];
        require(identity.deactivatedAt > 0, "Not deactivated");
        require(block.timestamp >= identity.deactivatedAt + deactivationCooldown, "Cooldown not complete");
        
        uint256 amount = identity.stakedAmount;
        identity.stakedAmount = 0;
        
        // Clear owner mapping
        delete ownerToIdentity[msg.sender];
        
        require(usdc.transfer(msg.sender, amount), "Withdraw failed");
        
        emit StakeWithdrawn(identityHash, amount);
    }

    // View functions
    
    function getIdentity(bytes32 identityHash) external view returns (
        address owner,
        address signingKey,
        string memory name,
        string memory metadataUri,
        uint256 stakedAmount,
        uint256 registeredAt,
        uint256 deactivatedAt,
        uint256 totalVouchesReceived
    ) {
        AgentIdentity storage i = identities[identityHash];
        return (i.owner, i.signingKey, i.name, i.metadataUri, i.stakedAmount, i.registeredAt, i.deactivatedAt, i.totalVouchesReceived);
    }

    function getLinkedPlatforms(bytes32 identityHash) external view returns (string[] memory) {
        return linkedPlatforms[identityHash];
    }

    function getVouchCount(bytes32 identityHash) external view returns (uint256) {
        return vouches[identityHash].length;
    }

    function isActive(bytes32 identityHash) external view returns (bool) {
        return identities[identityHash].owner != address(0) && identities[identityHash].deactivatedAt == 0;
    }

    // Admin functions
    
    function setMinStake(uint256 _minStake) external onlyOwner {
        minStake = _minStake;
    }

    function setDeactivationCooldown(uint256 _cooldown) external onlyOwner {
        deactivationCooldown = _cooldown;
    }
}
