// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title IdentitySoulboundToken
 * @dev A soulbound (non-transferable) token implementation for identity verification 
 * and role management in the loan crowdfunding platform.
 * 
 * This token represents an identity credential that cannot be transferred, and
 * contains data about the verification status and permissions of platform participants.
 */
contract IdentitySoulboundToken is ERC721URIStorage, AccessControl {
    using ECDSA for bytes32;

    // Role definitions
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant PLATFORM_ROLE = keccak256("PLATFORM_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    
    // Token counter for issuing new tokens
    uint256 private _tokenIdCounter;
    
    // Participant types in the platform
    enum ParticipantType { 
        Client,        // Can create loan requests and pledge collateral
        Investor,      // Can invest in loans
        Auditor,       // Can verify milestones and approve requests
        ServiceProvider // Other service providers (e.g., KYC providers, insurers)
    }
    
    // Risk categories for investors based on regulation
    enum RiskTolerance {
        Unspecified,
        Conservative,  // Low risk appetite
        Moderate,      // Medium risk appetite
        Aggressive     // High risk appetite
    }
    
    // Accreditation status for regulatory compliance
    enum AccreditationStatus {
        Unspecified,
        NonAccredited,         // Retail investors
        AccreditedIndividual,  // High net worth individuals
        InstitutionalInvestor  // Investment firms, funds, etc.
    }
    
    // Verification data structure for each SBT
    struct VerificationData {
        ParticipantType participantType;
        uint64 verificationDate;
        uint64 expirationDate;         // When verification expires
        string jurisdiction;           // Jurisdiction code (e.g., "US-NY", "UK", "SG")
        bytes32 documentHash;          // Hash of KYC/verification documents
        uint32 investmentLimitUSD;     // Maximum investment amount in USD (for investors)
        RiskTolerance riskTolerance;   // Risk profile (for investors)
        AccreditationStatus accreditationStatus; // Regulatory status
        bool isSanctioned;             // Compliance flag
        address[] allowedPlatforms;    // Platforms where this verification is valid
    }
    
    // Maps tokenId to verification data
    mapping(uint256 => VerificationData) public verifications;
    
    // Maps wallet address to their token ID(s)
    mapping(address => uint256[]) public addressToTokenIds;
    
    // Maps platform addresses to whether they're registered
    mapping(address => bool) public registeredPlatforms;
    
    // Maps document hash to whether it's been used
    mapping(bytes32 => bool) public usedDocumentHashes;
    
    // Events
    event ParticipantVerified(uint256 indexed tokenId, address indexed participant, ParticipantType participantType);
    event VerificationRevoked(uint256 indexed tokenId, address indexed participant);
    event VerificationExpired(uint256 indexed tokenId, address indexed participant);
    event ComplianceStatusUpdated(uint256 indexed tokenId, address indexed participant, bool isSanctioned);
    event PlatformRegistered(address indexed platformAddress);
    event PlatformRemoved(address indexed platformAddress);

    /**
     * @dev Constructor initializes the token with name and symbol
     */
    constructor() ERC721("Identity Verification Credential", "IVC") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VERIFIER_ROLE, msg.sender);
        _grantRole(COMPLIANCE_ROLE, msg.sender);
    }
    
    /**
     * @dev Prevents token transfers, making it "soulbound" to the recipient
     */
    function _update(address to, uint256 tokenId, address auth) 
    internal virtual override returns (address from) 
{
    from = super._update(to, tokenId, auth);
    
    // If this is a transfer (not a mint or burn)
    if (from != address(0) && to != address(0)) {
        revert("IdentitySoulboundToken: tokens are soulbound and cannot be transferred");
    }
    
    return from;
}
    
    /**
     * @dev Registers a platform that can use these verification tokens
     * @param platformAddress Address of the loan crowdfunding platform
     */
    function registerPlatform(address platformAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(platformAddress != address(0), "Invalid platform address");
        registeredPlatforms[platformAddress] = true;
        emit PlatformRegistered(platformAddress);
    }
    
    /**
     * @dev Removes a platform registration
     * @param platformAddress Address of the platform to remove
     */
    function removePlatform(address platformAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(registeredPlatforms[platformAddress], "Platform not registered");
        registeredPlatforms[platformAddress] = false;
        emit PlatformRemoved(platformAddress);
    }
    
    /**
     * @dev Issues a verification credential to a client
     * @param recipient Address of the client to verify
     * @param jurisdiction Jurisdiction code where the client is registered
     * @param documentHash Hash of verification documents
     * @param expirationDate When the verification expires (0 for no expiration)
     * @param tokenURI Optional URI for metadata about this verification
     * @return tokenId The ID of the newly minted token
     */
    function verifyClient(
        address recipient,
        string calldata jurisdiction,
        bytes32 documentHash,
        uint64 expirationDate,
        string calldata tokenURI
    ) external onlyRole(VERIFIER_ROLE) returns (uint256) {
        return _issueVerification(
            recipient,
            ParticipantType.Client,
            jurisdiction,
            documentHash,
            expirationDate,
            0, // No investment limit for clients
            RiskTolerance.Unspecified,
            AccreditationStatus.Unspecified,
            tokenURI
        );
    }
    
    /**
     * @dev Issues a verification credential to an investor with investment parameters
     * @param recipient Address of the investor to verify
     * @param jurisdiction Jurisdiction code where the investor is registered
     * @param documentHash Hash of verification documents
     * @param expirationDate When the verification expires (0 for no expiration)
     * @param investmentLimitUSD Maximum USD value the investor can invest
     * @param riskTolerance Risk profile of the investor
     * @param accreditationStatus Regulatory accreditation status
     * @param tokenURI Optional URI for metadata about this verification
     * @return tokenId The ID of the newly minted token
     */
    function verifyInvestor(
        address recipient,
        string calldata jurisdiction,
        bytes32 documentHash,
        uint64 expirationDate,
        uint32 investmentLimitUSD,
        RiskTolerance riskTolerance,
        AccreditationStatus accreditationStatus,
        string calldata tokenURI
    ) external onlyRole(VERIFIER_ROLE) returns (uint256) {
        return _issueVerification(
            recipient,
            ParticipantType.Investor,
            jurisdiction,
            documentHash,
            expirationDate,
            investmentLimitUSD,
            riskTolerance,
            accreditationStatus,
            tokenURI
        );
    }
    
    /**
     * @dev Issues a verification credential to an auditor
     * @param recipient Address of the auditor to verify
     * @param jurisdiction Jurisdiction code where the auditor is registered
     * @param documentHash Hash of verification documents
     * @param expirationDate When the verification expires (0 for no expiration)
     * @param tokenURI Optional URI for metadata about this verification
     * @return tokenId The ID of the newly minted token
     */
    function verifyAuditor(
        address recipient,
        string calldata jurisdiction,
        bytes32 documentHash,
        uint64 expirationDate,
        string calldata tokenURI
    ) external onlyRole(VERIFIER_ROLE) returns (uint256) {
        return _issueVerification(
            recipient,
            ParticipantType.Auditor,
            jurisdiction,
            documentHash,
            expirationDate,
            0, // No investment limit for auditors
            RiskTolerance.Unspecified,
            AccreditationStatus.Unspecified,
            tokenURI
        );
    }
    
    /**
     * @dev Issues a verification credential to a service provider
     * @param recipient Address of the service provider to verify
     * @param jurisdiction Jurisdiction code where the provider is registered
     * @param documentHash Hash of verification documents
     * @param expirationDate When the verification expires (0 for no expiration)
     * @param tokenURI Optional URI for metadata about this verification
     * @return tokenId The ID of the newly minted token
     */
    function verifyServiceProvider(
        address recipient,
        string calldata jurisdiction,
        bytes32 documentHash,
        uint64 expirationDate,
        string calldata tokenURI
    ) external onlyRole(VERIFIER_ROLE) returns (uint256) {
        return _issueVerification(
            recipient,
            ParticipantType.ServiceProvider,
            jurisdiction,
            documentHash,
            expirationDate,
            0, // No investment limit for service providers
            RiskTolerance.Unspecified,
            AccreditationStatus.Unspecified,
            tokenURI
        );
    }
    
    /**
     * @dev Internal function to issue verification credentials
     */

function _issueVerification(
    address recipient,
    ParticipantType participantType,
    string calldata jurisdiction,
    bytes32 documentHash,
    uint64 expirationDate,
    uint32 investmentLimitUSD,
    RiskTolerance riskTolerance,
    AccreditationStatus accreditationStatus,
    string calldata tokenURI
) internal returns (uint256) {
    require(recipient != address(0), "Recipient cannot be zero address");
    require(bytes(jurisdiction).length > 0, "Jurisdiction cannot be empty");
    require(documentHash != bytes32(0), "Document hash cannot be empty");
    require(!usedDocumentHashes[documentHash], "Document hash already used");
    
    if (expirationDate != 0) {
        require(expirationDate > block.timestamp, "Expiration date must be in the future");
    }
    
    // Mark the document hash as used
    usedDocumentHashes[documentHash] = true;
    
    // Mint a new token (manual counter increment)
    uint256 tokenId = _tokenIdCounter;  // Get the current token ID
    _tokenIdCounter++;  // Increment the counter manually
    
    _mint(recipient, tokenId);  // Mint the new token
    
    // Set token URI if provided
    if (bytes(tokenURI).length > 0) {
        _setTokenURI(tokenId, tokenURI);
    }
    
    // Create verification data
    VerificationData storage data = verifications[tokenId];
    data.participantType = participantType;
    data.verificationDate = uint64(block.timestamp);
    data.expirationDate = expirationDate;
    data.jurisdiction = jurisdiction;
    data.documentHash = documentHash;
    data.investmentLimitUSD = investmentLimitUSD;
    data.riskTolerance = riskTolerance; 
    data.accreditationStatus = accreditationStatus;
    data.isSanctioned = false;
    
    // Add all current registered platforms
    // This ensures that any platforms registered after a user is verified
    // won't automatically get access to their data
    address[] storage platforms = data.allowedPlatforms;
    for (uint i = 0; i < 10; i++) { // Limit platforms to prevent gas issues
        // Pseudo implementation - in reality you'd use a mapping or array of registered platforms
        address platformAddress = getPlatformAddressByIndex(i);
        if (platformAddress == address(0)) break;
        platforms.push(platformAddress);
    }
    
    // Map the address to the token ID
    addressToTokenIds[recipient].push(tokenId);
    
    emit ParticipantVerified(tokenId, recipient, participantType);
    
    return tokenId;
}

    
    /**
     * @dev Helper function to get platform addresses
     * This is a simplified implementation - in a real system, you would
     * likely use a mapping or array to store and retrieve platform addresses
     */
    function getPlatformAddressByIndex(uint256 _index) internal pure returns (address) {
    // This is just a placeholder implementation
    // You would need to replace this with your actual logic for retrieving
    // registered platforms based on the index
    return address(0);
}

    
    /**
     * @dev Updates the compliance status of a participant
     * @param tokenId Token ID to update
     * @param isSanctioned New sanction status
     */
    function updateComplianceStatus(uint256 tokenId, bool isSanctioned) 
        external 
        onlyRole(COMPLIANCE_ROLE) 
    {
require(_ownerOf(tokenId) != address(0), "Token does not exist");
        
        verifications[tokenId].isSanctioned = isSanctioned;
        
        emit ComplianceStatusUpdated(tokenId, ownerOf(tokenId), isSanctioned);
    }
    
    /**
     * @dev Revokes a verification by burning the token
     * @param tokenId Token ID to revoke
     */
    function revokeVerification(uint256 tokenId) external onlyRole(VERIFIER_ROLE) {
require(_ownerOf(tokenId) != address(0), "Token does not exist");
        
        address owner = ownerOf(tokenId);
        
        // Remove the token ID from the address mapping
        uint256[] storage tokenIds = addressToTokenIds[owner];
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (tokenIds[i] == tokenId) {
                // Replace with the last element and pop
                tokenIds[i] = tokenIds[tokenIds.length - 1];
                tokenIds.pop();
                break;
            }
        }
        
        // Burn the token
        _burn(tokenId);
        
        emit VerificationRevoked(tokenId, owner);
    }
    
    /**
     * @dev Checks if a participant is verified for a specific platform
     * @param participant Address of the participant to check
     * @param platform Address of the platform to check
     * @param requiredType Required participant type (use uint8 value of enum)
     * @return isVerified Whether the participant is verified
     * @return tokenId The token ID of the verification
     * @return pType The participant type
     * @return expiration When the verification expires
     * @return investmentLimit Maximum investment amount (for investors)
     * @return accreditation Accreditation status
     */
function checkVerification(
    address participant,
    address platform,
    ParticipantType requiredType
) external view returns (
    bool isVerified,
    uint256 tokenId,
    ParticipantType pType,
    uint64 expiration,
    uint32 investmentLimit,
    AccreditationStatus accreditation
) {
    require(participant != address(0), "Invalid participant address");
    
    // Check if the platform is registered
    if (!registeredPlatforms[platform]) {
        return (false, 0, ParticipantType.Client, 0, 0, AccreditationStatus.Unspecified);
    }
    
    // Get all tokens owned by this participant
    uint256[] memory tokenIds = addressToTokenIds[participant];
    
    // Find a valid token for this platform and participant type
    for (uint256 i = 0; i < tokenIds.length; i++) {
        uint256 id = tokenIds[i];
        
        // Check if token exists (using _ownerOf instead of _exists)
        if (_ownerOf(id) != address(0) && verifications[id].participantType == requiredType) {
            VerificationData storage data = verifications[id];
            
            // Check if it's expired
            bool expired = data.expirationDate != 0 && data.expirationDate < block.timestamp;
            if (expired) {
                continue;
            }
            
            // Check if participant is sanctioned
            if (data.isSanctioned) {
                continue;
            }
            
            // Check if platform is allowed
            bool platformAllowed = false;
            for (uint256 j = 0; j < data.allowedPlatforms.length; j++) {
                if (data.allowedPlatforms[j] == platform) {
                    platformAllowed = true;
                    break;
                }
            }
            
            if (!platformAllowed) {
                continue;
            }
            
            // Found a valid verification
            return (
                true,
                id,
                data.participantType,
                data.expirationDate,
                data.investmentLimitUSD,
                data.accreditationStatus
            );
        }
    }
    
    // No valid verification found
    return (false, 0, ParticipantType.Client, 0, 0, AccreditationStatus.Unspecified);
}

    /**
     * @dev Gets the verification details for a specific token
     * @param tokenId The token ID to query
     * @return participantType The type of participant
     * @return verificationDate When the verification was issued
     * @return expirationDate When the verification expires
     * @return jurisdiction Legal jurisdiction
     * @return documentHash Hash of verification documents
     * @return investmentLimitUSD Maximum investment amount
     * @return riskTolerance Risk profile
     * @return accreditationStatus Regulatory status
     * @return isSanctioned Whether the participant is sanctioned
     */
    function getVerificationDetails(uint256 tokenId) external view returns (
        ParticipantType participantType,
        uint64 verificationDate,
        uint64 expirationDate,
        string memory jurisdiction,
        bytes32 documentHash,
        uint32 investmentLimitUSD,
        RiskTolerance riskTolerance,
        AccreditationStatus accreditationStatus,
        bool isSanctioned
    ) {
require(_ownerOf(tokenId) != address(0), "Token does not exist");
        
        VerificationData storage data = verifications[tokenId];
        
        return (
            data.participantType,
            data.verificationDate,
            data.expirationDate,
            data.jurisdiction,
            data.documentHash,
            data.investmentLimitUSD,
            data.riskTolerance,
            data.accreditationStatus,
            data.isSanctioned
        );
    }
    
    /**
     * @dev Gets all token IDs for a specific address
     * @param owner The address to query
     * @return An array of token IDs
     */
    function getTokensByAddress(address owner) external view returns (uint256[] memory) {
        return addressToTokenIds[owner];
    }
    
    /**
     * @dev Check if a verification is expired
     * @param tokenId The token ID to check
     * @return True if expired, false otherwise
     */
    function isExpired(uint256 tokenId) external view returns (bool) {
require(_ownerOf(tokenId) != address(0), "Token does not exist");
        
        uint64 expiration = verifications[tokenId].expirationDate;
        
        if (expiration == 0) {
            return false; // No expiration
        }
        
        return block.timestamp > expiration;
    }
    
    /**
     * @dev Required override to support both ERC721 and AccessControl
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721URIStorage, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}