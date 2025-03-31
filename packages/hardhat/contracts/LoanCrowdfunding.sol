// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./IdentitySoulboundToken.sol";
import "./GovToken.sol";
import "./PriceFeedManager.sol";

/**
 * @title LoanCrowdfunding
 * @dev A contract for managing loan-based crowdfunding with pledged collateral,
 * periodic repayments, and governance voting for late payments.
 * Enhanced with identity verification using Soulbound Tokens and
 * Chainlink price feeds for accurate USD/token conversions.
 */
contract LoanCrowdfunding is ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // Roles
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    bytes32 public constant CLIENT_ROLE = keccak256("CLIENT_ROLE");
    bytes32 public constant PRICE_FEED_MANAGER_ROLE = keccak256("PRICE_FEED_MANAGER_ROLE");

    // Enums
    enum LoanStatus { 
        Inactive,
        PledgeSubmitted,
        InvestmentActive,
        FundingSuccessful,
        FundingFailed,
        FundsWithdrawn,
        InRepayment,
        Completed,
        Defaulted 
    }
    
    enum VoteStatus { 
        NotStarted,
        Active,
        Completed 
    }

    // Structs - Packed for gas efficiency
    struct Pledge {
        address tokenAddress;    // Address of the token used as collateral
        uint128 tokenAmount;     // Amount of tokens pledged - 128 bits is plenty (> 10^38)
        bytes32 documentHash;    // Hash of the pledge document
        bool locked;             // Whether the pledge is locked
    }

    struct Loan {
        uint128 targetAmount;        // Target funding amount
        uint128 totalFunded;         // Total amount funded
        uint128 remainingBalance;    // Remaining loan balance to be repaid
        uint64 investmentPeriod;     // End time for investments
        uint64 withdrawalDeadline;   // Deadline for client to withdraw funds
        uint64 repaymentInterval;    // Interval between repayments in seconds
        uint32 interestRate;         // Annual interest rate (basis points)
        uint64 nextRepaymentDate;    // Timestamp for next repayment
        uint16 totalRepayments;      // Total number of repayments
        uint16 completedRepayments;  // Number of completed repayments
        uint32 riskRating;           // Risk rating (1-100)
        string jurisdiction;         // Legal jurisdiction for this loan
    }

    struct Repayment {
        uint128 amount;          // Basic repayment amount
        uint128 penalty;         // Additional penalty amount
        uint64 dueDate;          // Due date for the repayment
        uint64 paidDate;         // Date when repayment was made
        bool paid;               // Whether repayment has been paid
    }

    struct Vote {
        uint64 startTime;        // Start time of vote
        uint64 endTime;          // End time of vote
        uint128 votesFor;        // Votes for expropriation
        uint128 votesAgainst;    // Votes against expropriation
        VoteStatus status;       // Current status of the vote
        bool expropriationApproved; // Result of vote
    }

    // Immutable state variables
    address public immutable client;
    IERC20 public immutable stablecoin;
    GovToken public immutable govToken;
    IdentitySoulboundToken public immutable identityToken;
    
    // Price feed manager
    PriceFeedManager public priceFeedManager;
    
    // Constants
    uint256 public constant LATE_PAYMENT_THRESHOLD = 90 days; // 3 months
    uint256 public constant WITHDRAW_PERIOD = 3 days; // 3 working days
    uint256 public constant VOTING_PERIOD = 7 days;
    uint256 public constant MIN_VOTE_PARTICIPATION = 30; // 30% participation required
    uint256 public constant EXPROPRIATION_THRESHOLD = 51; // 51% for expropriation
    uint256 public constant MAX_REPAYMENTS = 60; // Safety cap on repayments
    uint256 public constant MINIMUM_COLLATERAL_RATIO = 120; // 120% minimum collateral value

    // State variables
    LoanStatus public loanStatus;
    Pledge public pledge;
    Loan public loan;
    Vote public currentVote;
    bool private _initialized; // Prevents double initialization
    uint32 public minCreditScore; // Minimum credit score for investors
    
    // Mappings
    mapping(address => uint256) public investments;
    mapping(address => bool) public hasClaimedGovTokens;
    mapping(address => bool) public hasClaimedRefund;
    mapping(uint256 => Repayment) public repayments;
    mapping(address => mapping(uint256 => bool)) public investorVoted;
    mapping(uint256 => mapping(address => uint256)) public repaymentClaims;
    mapping(address => uint256) public pledgeSharesClaimed; // Tracks claimed shares to avoid double claims

    // Events
    event PledgeSubmitted(address indexed tokenAddress, uint256 amount, bytes32 documentHash);
    event PledgeLocked(address indexed tokenAddress, uint256 amount);
    event PledgeUnlocked(address indexed tokenAddress, uint256 amount);
    event PledgeWithdrawn(address indexed recipient, address tokenAddress, uint256 amount);
    event InvestmentReceived(address indexed investor, uint256 amount, uint256 timestamp);
    event FundingSuccessful(uint256 totalFunded);
    event FundingFailed(uint256 totalFunded);
    event FundsWithdrawn(address indexed client, uint256 amount);
    event GovTokensClaimed(address indexed investor, uint256 amount);
    event RefundClaimed(address indexed investor, uint256 amount);
    event RepaymentScheduled(uint256 indexed repaymentId, uint256 amount, uint256 dueDate);
    event RepaymentReceived(uint256 indexed repaymentId, uint256 amount, uint256 penalty);
    event RepaymentProfit(address indexed investor, uint256 repaymentId, uint256 amount);
    event VoteStarted(uint256 repaymentId, uint256 startTime, uint256 endTime);
    event VoteCast(address indexed voter, bool support, uint256 weight);
    event VoteCompleted(bool expropriationApproved, uint256 votesFor, uint256 votesAgainst);
    event LoanCompleted();
    event LoanDefaulted();
    event PenaltyCalculated(uint256 indexed repaymentId, uint256 penalty, uint256 weeksLate);
    event EmergencyPaused(address indexed by);
    event EmergencyUnpaused(address indexed by);
    event InvestorVerified(address indexed investor, uint256 tokenId);
    event ClientVerified(address indexed client);
    event RiskRatingUpdated(uint32 newRating);
    event InvestmentLimitReached(address indexed investor, uint256 amount, uint256 limit);
    event PriceFeedManagerSet(address indexed priceFeedManager);
    event CollateralValueConverted(uint256 usdValue, uint256 tokenAmount, address tokenAddress);

    // Modifiers
    modifier onlyVerifiedClient() {
        (bool isVerified, , , , , ) = identityToken.checkVerification(
            msg.sender, 
            address(this),
            IdentitySoulboundToken.ParticipantType.Client
        );
        require(isVerified, "Not a verified client");
        require(msg.sender == client, "Not the loan client");
        _;
    }

    modifier onlyVerifiedInvestor() {
        (bool isVerified, , , , , ) = identityToken.checkVerification(
            msg.sender, 
            address(this),
            IdentitySoulboundToken.ParticipantType.Investor
        );
        require(isVerified, "Not a verified investor");
        _;
    }

    modifier onlyVerifiedAuditor() {
        (bool isVerified, , , , , ) = identityToken.checkVerification(
            msg.sender, 
            address(this),
            IdentitySoulboundToken.ParticipantType.Auditor
        );
        require(isVerified, "Not a verified auditor");
        require(hasRole(AUDITOR_ROLE, msg.sender), "Not an auditor");
        _;
    }

    modifier onlyInvestor() {
        require(investments[msg.sender] > 0, "Only investors can call this function");
        _;
    }

    modifier atStatus(LoanStatus _status) {
        require(loanStatus == _status, "Invalid loan status for this action");
        _;
    }

    modifier notInitialized() {
        require(!_initialized, "Contract already initialized");
        _;
    }

    /**
     * @dev Constructor that initializes all immutable variables
     * @param _client Address of the client (borrower)
     * @param _stablecoin Address of the stablecoin contract
     * @param _identityToken Address of the IdentitySoulboundToken contract
     */
    constructor(
        address _client,
        address _stablecoin,
        address _identityToken
    ) {
        require(_client != address(0), "Client cannot be zero address");
        require(_stablecoin != address(0), "Stablecoin cannot be zero address");
        require(_identityToken != address(0), "Identity token cannot be zero address");
        
        // Verify client has a valid soulbound token
        IdentitySoulboundToken iToken = IdentitySoulboundToken(_identityToken);
        (bool isVerified, , , , , ) = iToken.checkVerification(
            _client,
            address(this),
            IdentitySoulboundToken.ParticipantType.Client
        );
        // require(isVerified, "Client must have a valid SBT verification"); 
        require(true, "Client must have a valid SBT verification"); //just for testing assume it is ture. then remove it and uncomment the line above
        
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(AUDITOR_ROLE, msg.sender);
        _grantRole(CLIENT_ROLE, _client);
        _grantRole(PRICE_FEED_MANAGER_ROLE, msg.sender);
        
        client = _client;
        stablecoin = IERC20(_stablecoin);
        identityToken = iToken;
        
        // Deploy the governance token
        govToken = new GovToken();
        // Grant this contract the minter role
        govToken.grantRole(govToken.MINTER_ROLE(), address(this));
        
        loanStatus = LoanStatus.Inactive;
        minCreditScore = 0; // Default no minimum
    }

    /**
     * @dev Set the minimum credit score required for investors
     * @param _minCreditScore The minimum score (0-100)
     */
    function setMinCreditScore(uint32 _minCreditScore) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_minCreditScore <= 100, "Score must be 0-100");
        minCreditScore = _minCreditScore;
    }
    
    /**
     * @dev Set the price feed manager contract
     * @param _priceFeedManager Address of the PriceFeedManager contract
     */
    function setPriceFeedManager(address _priceFeedManager) external onlyRole(PRICE_FEED_MANAGER_ROLE) {
        require(_priceFeedManager != address(0), "PriceFeedManager cannot be zero address");
        priceFeedManager = PriceFeedManager(_priceFeedManager);
        emit PriceFeedManagerSet(_priceFeedManager);
    }

    /**
     * @dev Initialize the loan contract with all necessary parameters
     * @param _targetAmount The target funding amount
     * @param _investmentPeriod Duration of investment period in seconds
     * @param _repaymentInterval Time between repayments in seconds
     * @param _totalRepayments Total number of repayments
     * @param _interestRate Annual interest rate in basis points (1000 = 10%)
     * @param _riskRating Risk rating for the loan (1-100)
     * @param _jurisdiction Jurisdiction code for this loan
     */
    function initialize(
        uint256 _targetAmount,
        uint256 _investmentPeriod,
        uint256 _repaymentInterval,
        uint256 _totalRepayments,
        uint256 _interestRate,
        uint32 _riskRating,
        string calldata _jurisdiction
    ) external onlyVerifiedAuditor notInitialized {
        require(_targetAmount > 0 && _targetAmount <= type(uint128).max, "Invalid target amount");
        require(_investmentPeriod > 0, "Investment period must be greater than zero");
        require(_repaymentInterval > 0, "Repayment interval must be greater than zero");
        require(_totalRepayments > 0 && _totalRepayments <= MAX_REPAYMENTS, "Invalid repayment count");
        require(_interestRate <= 10000, "Interest rate cannot exceed 100%"); // 10000 basis points = 100%
        require(_riskRating > 0 && _riskRating <= 100, "Risk rating must be 1-100");
        require(bytes(_jurisdiction).length > 0, "Jurisdiction cannot be empty");
        
        loan = Loan({
            targetAmount: uint128(_targetAmount),
            investmentPeriod: uint64(block.timestamp + _investmentPeriod),
            withdrawalDeadline: 0, // Will be set once funding is successful
            totalFunded: 0,
            remainingBalance: uint128(_targetAmount),
            repaymentInterval: uint64(_repaymentInterval),
            interestRate: uint32(_interestRate),
            nextRepaymentDate: 0, // Will be set once client withdraws funds
            totalRepayments: uint16(_totalRepayments),
            completedRepayments: 0,
            riskRating: _riskRating,
            jurisdiction: _jurisdiction
        });
        
        // Calculate repayment amounts
        uint256 totalInterest = (_targetAmount * _interestRate * _totalRepayments * _repaymentInterval) / (10000 * 365 days);
        uint256 totalToRepay = _targetAmount + totalInterest;
        uint256 repaymentAmount = totalToRepay / _totalRepayments;
        
        // Schedule repayments
        for (uint256 i = 0; i < _totalRepayments; i++) {
            repayments[i] = Repayment({
                amount: uint128(repaymentAmount),
                penalty: 0,
                dueDate: 0, // Will be set once client withdraws funds
                paidDate: 0,
                paid: false
            });
            
            emit RepaymentScheduled(i, repaymentAmount, 0);
        }
        
        loanStatus = LoanStatus.PledgeSubmitted;
        _initialized = true;
        
        emit RiskRatingUpdated(_riskRating);
    }

    /**
     * @dev Emergency pause - halts critical contract operations
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
        emit EmergencyPaused(msg.sender);
    }

    /**
     * @dev Resume contract operations after pause
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
        emit EmergencyUnpaused(msg.sender);
    }

    /**
     * @dev Submit pledge as collateral
     * @param tokenAddress Address of the token to pledge
     * @param amount Amount of tokens to pledge
     * @param documentHash Hash of the pledge document
     */
    function submitPledge(
        address tokenAddress,
        uint256 amount,
        bytes32 documentHash
    ) external onlyVerifiedClient atStatus(LoanStatus.PledgeSubmitted) whenNotPaused {
        require(amount > 0 && amount <= type(uint128).max, "Invalid pledge amount");
        require(documentHash != bytes32(0), "Document hash cannot be empty");
        require(IERC20(tokenAddress).allowance(client, address(this)) >= amount, "Allowance too low");
        
        // Verify sufficient collateral value against the loan amount
        if (address(priceFeedManager) != address(0)) {
            try priceFeedManager.tokenToUsd(amount, tokenAddress) returns (uint256 pledgeValueUsd) {
                try priceFeedManager.tokenToUsd(loan.targetAmount, address(stablecoin)) returns (uint256 loanValueUsd) {
                    // Require collateral to be at least MINIMUM_COLLATERAL_RATIO% of loan value
                    require(
                        pledgeValueUsd >= (loanValueUsd * MINIMUM_COLLATERAL_RATIO) / 100, 
                        "Insufficient collateral value"
                    );
                    
                    emit CollateralValueConverted(pledgeValueUsd, amount, tokenAddress);
                } catch {
                    // If loan value conversion fails, we still accept the pledge but emit no event
                }
            } catch {
                // If pledge value conversion fails, we still accept the pledge but emit no event
            }
        }
        
        // Security check to prevent token manipulation
        uint256 balanceBefore = IERC20(tokenAddress).balanceOf(address(this));
        
        // Transfer tokens to contract
        IERC20(tokenAddress).safeTransferFrom(client, address(this), amount);
        
        // Verify the actual amount received
        uint256 balanceAfter = IERC20(tokenAddress).balanceOf(address(this));
        uint256 actualAmount = balanceAfter - balanceBefore;
        require(actualAmount > 0, "No tokens received");
        
        // Set pledge details
        pledge = Pledge({
            tokenAddress: tokenAddress,
            tokenAmount: uint128(actualAmount),
            documentHash: documentHash,
            locked: true
        });
        
        // Update status to start investment period
        loanStatus = LoanStatus.InvestmentActive;
        
        emit PledgeSubmitted(tokenAddress, actualAmount, documentHash);
        emit PledgeLocked(tokenAddress, actualAmount);
    }

    /**
     * @dev Invest in the loan
     * @param amount Amount to invest
     * @return success True if investment was successful
     */
    function invest(uint256 amount) external nonReentrant whenNotPaused onlyVerifiedInvestor atStatus(LoanStatus.InvestmentActive) returns (bool success) {
        require(amount > 0, "Investment amount must be greater than zero");
        require(block.timestamp <= loan.investmentPeriod, "Investment period has ended");
        
        // Verify investor's eligibility
        (bool isVerified, uint256 tokenId, , , uint32 investmentLimitUsd, IdentitySoulboundToken.AccreditationStatus accreditation) = 
            identityToken.checkVerification(
                msg.sender,
                address(this),
                IdentitySoulboundToken.ParticipantType.Investor
            );
            
        require(isVerified, "Not a verified investor");
        
        // Check risk tolerance compatibility with loan risk
        // This is simplified - in a real system you'd have more sophisticated checks
        if (loan.riskRating > 70) {
            // High risk loans require more than non-accredited investors
            require(
                accreditation == IdentitySoulboundToken.AccreditationStatus.AccreditedIndividual || 
                accreditation == IdentitySoulboundToken.AccreditationStatus.InstitutionalInvestor,
                "Loan risk too high for non-accredited investors"
            );
        }
         
        // Check investment limit using price feed for USD conversion if available
        if (investmentLimitUsd > 0) {
            uint256 alreadyInvested = investments[msg.sender];
            
            if (address(priceFeedManager) != address(0)) {
                // Convert USD investment limit to token amount using real-time price data
                try priceFeedManager.usdToToken(investmentLimitUsd, address(stablecoin)) returns (uint256 investmentLimitInTokens) {
                    require(alreadyInvested + amount <= investmentLimitInTokens, "Would exceed your investment limit");
                } catch {
                    // Fallback if price feed conversion fails: use simple conversion
                    uint8 tokenDecimals = IERC20Metadata(address(stablecoin)).decimals();
                    uint256 scaledLimit = uint256(investmentLimitUsd) * (10 ** (tokenDecimals - 2));
                    require(alreadyInvested + amount <= scaledLimit, "Would exceed your investment limit");
                }
            } else {
                // No price feed available, use simple conversion
                // This assumes the stablecoin has a 1:1 USD peg
                uint8 tokenDecimals = IERC20Metadata(address(stablecoin)).decimals();
                uint256 scaledLimit = uint256(investmentLimitUsd) * (10 ** (tokenDecimals - 2));
                require(alreadyInvested + amount <= scaledLimit, "Would exceed your investment limit");
            }
        }
        
        // Check if funding target would be exceeded
        uint256 newTotal = uint256(loan.totalFunded) + amount;
        require(newTotal <= loan.targetAmount, "Investment would exceed target amount");
        
        require(stablecoin.allowance(msg.sender, address(this)) >= amount, "Allowance too low");
        
        // Update state before external call
        investments[msg.sender] += amount;
        loan.totalFunded = uint128(newTotal);
        
        // Transfer stablecoins to contract
        uint256 balanceBefore = stablecoin.balanceOf(address(this));
        stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        
        // Verify the actual amount received
        uint256 balanceAfter = stablecoin.balanceOf(address(this));
        uint256 actualAmount = balanceAfter - balanceBefore;
        
        // If actual amount is different from expected, adjust investment records
        if (actualAmount != amount) {
            investments[msg.sender] = investments[msg.sender] - amount + actualAmount;
            loan.totalFunded = uint128(uint256(loan.totalFunded) - amount + actualAmount);
            amount = actualAmount;
        }
        
        emit InvestmentReceived(msg.sender, amount, block.timestamp);
        emit InvestorVerified(msg.sender, tokenId);
        
        // Check if target is reached
        if (loan.totalFunded >= loan.targetAmount) {
            loanStatus = LoanStatus.FundingSuccessful;
            loan.withdrawalDeadline = uint64(block.timestamp + WITHDRAW_PERIOD);
            emit FundingSuccessful(loan.totalFunded);
        }
        
        return true;
    }

    /**
     * @dev Update funding status after investment period ends
     */
    function updateFundingStatus() external whenNotPaused {
        require(loanStatus == LoanStatus.InvestmentActive, "Loan is not in active investment state");
        require(block.timestamp > loan.investmentPeriod, "Investment period has not ended yet");
        
        if (loan.totalFunded < loan.targetAmount) {
            loanStatus = LoanStatus.FundingFailed;
            emit FundingFailed(loan.totalFunded);
        } else {
            loanStatus = LoanStatus.FundingSuccessful;
            loan.withdrawalDeadline = uint64(block.timestamp + WITHDRAW_PERIOD);
            emit FundingSuccessful(loan.totalFunded);
        }
    }

    /**
     * @dev Claim GOV tokens for investors
     */
    function claimGovTokens() external nonReentrant whenNotPaused onlyVerifiedInvestor onlyInvestor {
        require(
            loanStatus == LoanStatus.FundingSuccessful || 
            loanStatus == LoanStatus.FundsWithdrawn || 
            loanStatus == LoanStatus.InRepayment, 
            "Funding must be successful to claim tokens"
        );
        require(!hasClaimedGovTokens[msg.sender], "GOV tokens already claimed");
        
        uint256 amount = investments[msg.sender];
        hasClaimedGovTokens[msg.sender] = true;
        
        // Mint GOV tokens to investor
        govToken.mint(msg.sender, amount);
        
        emit GovTokensClaimed(msg.sender, amount);
    }

    /**
     * @dev Withdraw funds by client
     */
    function withdrawFunds() external nonReentrant whenNotPaused onlyVerifiedClient atStatus(LoanStatus.FundingSuccessful) {
        require(block.timestamp <= loan.withdrawalDeadline, "Withdrawal period has expired");
        
        // Update status
        loanStatus = LoanStatus.FundsWithdrawn;
        
        // Set repayment schedule
        uint256 nextDate = block.timestamp;
        for (uint256 i = 0; i < loan.totalRepayments; i++) {
            nextDate += loan.repaymentInterval;
            repayments[i].dueDate = uint64(nextDate);
            
            emit RepaymentScheduled(i, repayments[i].amount, nextDate);
        }
        
        loan.nextRepaymentDate = uint64(repayments[0].dueDate);
        loanStatus = LoanStatus.InRepayment;
        
        // Get the amount to transfer
        uint256 amountToTransfer = loan.totalFunded;
        
        // Transfer funds to client
        stablecoin.safeTransfer(client, amountToTransfer);
        
        emit FundsWithdrawn(client, amountToTransfer);
    }

    /**
     * @dev Claim refund if funding failed or client didn't withdraw
     */
    function claimRefund() external nonReentrant whenNotPaused onlyVerifiedInvestor onlyInvestor {
        bool canClaim = false;
        
        // Case 1: Funding failed
        if (loanStatus == LoanStatus.FundingFailed) {
            canClaim = true;
        }
        
        // Case 2: Client didn't withdraw in time
        if (loanStatus == LoanStatus.FundingSuccessful && block.timestamp > loan.withdrawalDeadline) {
            loanStatus = LoanStatus.FundingFailed;
            emit FundingFailed(loan.totalFunded);
            canClaim = true;
        }
        
        require(canClaim, "Not eligible for refund");
        require(!hasClaimedRefund[msg.sender], "Refund already claimed");
        require(investments[msg.sender] > 0, "No investment to refund");
        
        uint256 amount = investments[msg.sender];
        hasClaimedRefund[msg.sender] = true;
        
        stablecoin.safeTransfer(msg.sender, amount);
        
        emit RefundClaimed(msg.sender, amount);
    }

    /**
     * @dev Unlock pledge if funding failed
     */
    function unlockPledge() external whenNotPaused onlyVerifiedClient {
        require(loanStatus == LoanStatus.FundingFailed, "Funding has not failed");
        require(pledge.locked, "Pledge already unlocked");
        
        pledge.locked = false;
        
        emit PledgeUnlocked(pledge.tokenAddress, pledge.tokenAmount);
    }

    /**
     * @dev Withdraw pledge if unlocked
     */
    function withdrawPledge() external nonReentrant whenNotPaused onlyVerifiedClient {
        require(!pledge.locked, "Pledge is still locked");
        require(pledge.tokenAmount > 0, "No pledge to withdraw");
        
        address tokenAddress = pledge.tokenAddress;
        uint256 amount = pledge.tokenAmount;
        
        // Reset pledge amount first to prevent reentrancy
        pledge.tokenAmount = 0;
        
        // Transfer tokens back to client
        IERC20(tokenAddress).safeTransfer(client, amount);
        
        emit PledgeWithdrawn(client, tokenAddress, amount);
        
        // If loan is completed and pledge withdrawn, mark as fully completed
        if (loanStatus == LoanStatus.Completed) {
            emit LoanCompleted();
        }
    }

    /**
     * @dev Calculate penalty for late repayment
     * @param dueDate The repayment due date
     * @param repaymentAmount The base repayment amount
     * @return penalty The calculated penalty amount
     * @return weeksLate Number of weeks the payment is late
     */
    function _calculatePenalty(uint64 dueDate, uint128 repaymentAmount) internal view returns (uint128 penalty, uint256 weeksLate) {
        if (block.timestamp <= dueDate) {
            return (0, 0);
        }
        
        // Calculate weeks late (1% penalty per week)
        weeksLate = (block.timestamp - dueDate) / (7 days);
        if (weeksLate > 0) {
            // Cap penalty at 50% of repayment to prevent excessive penalties
            uint256 calculatedPenalty = (uint256(repaymentAmount) * weeksLate) / 100;
            uint256 maxPenalty = uint256(repaymentAmount) / 2; // 50%
            penalty = uint128(calculatedPenalty > maxPenalty ? maxPenalty : calculatedPenalty);
        }
        
        return (penalty, weeksLate);
    }

    /**
     * @dev Make a repayment
     * @param repaymentId ID of the repayment
     */
    function makeRepayment(uint256 repaymentId) external nonReentrant whenNotPaused onlyVerifiedClient atStatus(LoanStatus.InRepayment) {
        require(repaymentId < loan.totalRepayments, "Invalid repayment ID");
        require(!repayments[repaymentId].paid, "Repayment already made");
        
        Repayment storage repayment = repayments[repaymentId];
        
        // Calculate penalty if late
        (uint128 penalty, uint256 weeksLate) = _calculatePenalty(repayment.dueDate, repayment.amount);
        repayment.penalty = penalty;
        
        if (penalty > 0) {
            emit PenaltyCalculated(repaymentId, penalty, weeksLate);
        }
        
        uint256 totalAmount = uint256(repayment.amount) + uint256(penalty);
        
        // Ensure sufficient allowance and balance
        
        require(stablecoin.allowance(client, address(this)) >= totalAmount, "Allowance too low");
        
        // Update repayment state before external calls
        repayment.paid = true;
        repayment.paidDate = uint64(block.timestamp);
        
        // Update loan state
        loan.remainingBalance = uint128(uint256(loan.remainingBalance) - uint256(repayment.amount));
        loan.completedRepayments++;
        
        // Transfer repayment to contract
        stablecoin.safeTransferFrom(client, address(this), totalAmount);
        
        emit RepaymentReceived(repaymentId, repayment.amount, penalty);
        
        // Update next repayment date if there are more repayments
        if (loan.completedRepayments < loan.totalRepayments) {
            loan.nextRepaymentDate = repayments[repaymentId + 1].dueDate;
        } else {
            // All repayments completed
            loanStatus = LoanStatus.Completed;
            pledge.locked = false;
            emit PledgeUnlocked(pledge.tokenAddress, pledge.tokenAmount);
        }
    }
    /**
     * @dev Claim repayment profit as an investor
     * @param repaymentId ID of the repayment
     */
    function claimRepaymentProfit(uint256 repaymentId) external nonReentrant whenNotPaused onlyVerifiedInvestor onlyInvestor {
        require(repaymentId < loan.totalRepayments, "Invalid repayment ID");
        require(repayments[repaymentId].paid, "Repayment not made yet");
        require(repaymentClaims[repaymentId][msg.sender] == 0, "Already claimed profit for this repayment");
        
        Repayment storage repayment = repayments[repaymentId];
        
        // Calculate investor's share based on their investment percentage
        uint256 totalAmount = uint256(repayment.amount) + uint256(repayment.penalty);
        uint256 investorShare = (investments[msg.sender] * totalAmount) / uint256(loan.totalFunded);
        
        // Record claim to prevent double claiming
        repaymentClaims[repaymentId][msg.sender] = investorShare;
        
        // Transfer profit to investor
        stablecoin.safeTransfer(msg.sender, investorShare);
        
        emit RepaymentProfit(msg.sender, repaymentId, investorShare);
    }

    /**
     * @dev Start a vote for expropriation due to late payment
     * @param repaymentId ID of the late repayment
     */
    function startExpropriationVote(uint256 repaymentId) external whenNotPaused onlyVerifiedInvestor onlyInvestor atStatus(LoanStatus.InRepayment) {
        require(repaymentId < loan.totalRepayments, "Invalid repayment ID");
        require(!repayments[repaymentId].paid, "Repayment already made");
        require(
            block.timestamp > repayments[repaymentId].dueDate + LATE_PAYMENT_THRESHOLD, 
            "Payment not late enough"
        );
        require(
            currentVote.status == VoteStatus.NotStarted || 
            currentVote.status == VoteStatus.Completed, 
            "Vote already in progress"
        );
        
        // Initialize vote
        currentVote = Vote({
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + VOTING_PERIOD),
            votesFor: 0,
            votesAgainst: 0,
            status: VoteStatus.Active,
            expropriationApproved: false
        });
        
        emit VoteStarted(repaymentId, currentVote.startTime, currentVote.endTime);
    }

    /**
     * @dev Cast a vote on expropriation
     * @param support True to vote for expropriation, false to vote against
     */
    function vote(bool support) external whenNotPaused onlyVerifiedInvestor onlyInvestor {
        require(currentVote.status == VoteStatus.Active, "No active vote");
        require(block.timestamp <= currentVote.endTime, "Voting period ended");
        require(!investorVoted[msg.sender][currentVote.startTime], "Already voted");
        
        // Mark as voted
        investorVoted[msg.sender][currentVote.startTime] = true;
        
        // Count vote based on GOV token balance
        uint256 voteWeight = govToken.balanceOf(msg.sender);
        require(voteWeight > 0, "No voting power");
        
        if (support) {
            // Check for overflow before adding
            require(uint256(currentVote.votesFor) + voteWeight <= type(uint128).max, "Vote count overflow");
            currentVote.votesFor += uint128(voteWeight);
        } else {
            // Check for overflow before adding
            require(uint256(currentVote.votesAgainst) + voteWeight <= type(uint128).max, "Vote count overflow");
            currentVote.votesAgainst += uint128(voteWeight);
        }
        
        emit VoteCast(msg.sender, support, voteWeight);
    }

    /**
     * @dev Finalize the vote and determine outcome
     */
    function finalizeVote() external whenNotPaused {
        require(currentVote.status == VoteStatus.Active, "No active vote");
        require(block.timestamp > currentVote.endTime, "Voting period not ended");
        
        // Calculate total votes and participation
        uint256 totalVotes = uint256(currentVote.votesFor) + uint256(currentVote.votesAgainst);
        uint256 totalGovTokens = govToken.totalSupply();
        
        // Prevent division by zero
        require(totalGovTokens > 0, "No governance tokens issued");
        
        uint256 participationRate = (totalVotes * 100) / totalGovTokens;
        
        // Check if quorum is reached
        bool quorumReached = participationRate >= MIN_VOTE_PARTICIPATION;
        
        // Determine outcome
        bool expropriationApproved = false;
        if (quorumReached && totalVotes > 0) {
            uint256 approvalRate = (uint256(currentVote.votesFor) * 100) / totalVotes;
            expropriationApproved = approvalRate >= EXPROPRIATION_THRESHOLD;
        }
        
        // Update vote status
        currentVote.status = VoteStatus.Completed;
        currentVote.expropriationApproved = expropriationApproved;
        
        if (expropriationApproved) {
            // Handle loan default
            loanStatus = LoanStatus.Defaulted;
            emit LoanDefaulted();
        }
        
        emit VoteCompleted(expropriationApproved, currentVote.votesFor, currentVote.votesAgainst);
    }

    /**
     * @dev Claim pledge after loan default (only investors)
     */
    function claimPledgeShare() external nonReentrant whenNotPaused onlyVerifiedInvestor onlyInvestor {
        require(loanStatus == LoanStatus.Defaulted, "Loan not defaulted");
        require(pledge.tokenAmount > 0, "No pledge to claim");
        
        uint256 investorAmount = investments[msg.sender];
        require(investorAmount > pledgeSharesClaimed[msg.sender], "Already claimed maximum share");
        
        // Calculate investor's share of the pledge
        uint256 remainingShare = investorAmount - pledgeSharesClaimed[msg.sender];
        uint256 investorShare = (remainingShare * uint256(pledge.tokenAmount)) / uint256(loan.totalFunded);
        
        // Ensure investor hasn't already claimed
        require(investorShare > 0, "No share to claim");
        
        // Update claim record to prevent double claiming
        pledgeSharesClaimed[msg.sender] += remainingShare;
        
        // Update pledge amount
        uint256 newPledgeAmount = uint256(pledge.tokenAmount) - investorShare;
        require(newPledgeAmount <= type(uint128).max, "Pledge amount overflow");
        pledge.tokenAmount = uint128(newPledgeAmount);
        
        // Transfer pledge tokens to investor
        IERC20(pledge.tokenAddress).safeTransfer(msg.sender, investorShare);
        
        emit PledgeWithdrawn(msg.sender, pledge.tokenAddress, investorShare);
    }

    /**
     * @dev Check if a caller is a verified investor
     * @param investor Address to check
     * @return isVerified Whether the address is a verified investor
     * @return investmentLimit Maximum investment amount in USD
     * @return accreditationStatus Accreditation status
     */
    function checkInvestorStatus(address investor) external view returns (
        bool isVerified,
        uint256 investmentLimit,
        IdentitySoulboundToken.AccreditationStatus accreditationStatus
    ) {
        (bool verified, , , , uint32 limit, IdentitySoulboundToken.AccreditationStatus status) = 
            identityToken.checkVerification(
                investor, 
                address(this),
                IdentitySoulboundToken.ParticipantType.Investor
            );
            
        return (verified, limit, status);
    }

    /**
     * @dev Get loan details
     * @return status The current status of the loan
     * @return targetAmount The target funding amount
     * @return totalFunded The total amount funded so far
     * @return remainingBalance The remaining loan balance to be repaid
     * @return nextRepaymentDate The timestamp for the next repayment
     * @return completedRepayments The number of completed repayments
     * @return totalRepayments The total number of repayments scheduled
     * @return riskRating The risk rating of the loan (1-100)
     * @return jurisdiction The legal jurisdiction for this loan
     */
    function getLoanDetails() external view returns (
        LoanStatus status,
        uint256 targetAmount,
        uint256 totalFunded,
        uint256 remainingBalance,
        uint256 nextRepaymentDate,
        uint256 completedRepayments,
        uint256 totalRepayments,
        uint32 riskRating,
        string memory jurisdiction
    ) {
        return (
            loanStatus,
            loan.targetAmount,
            loan.totalFunded,
            loan.remainingBalance,
            loan.nextRepaymentDate,
            loan.completedRepayments,
            loan.totalRepayments,
            loan.riskRating,
            loan.jurisdiction
        );
    }

    /**
     * @dev Get pledge details
     * @return tokenAddress The address of the token used as collateral
     * @return tokenAmount The amount of tokens pledged
     * @return documentHash The hash of the pledge document
     * @return locked Whether the pledge is currently locked
     */
    function getPledgeDetails() external view returns (
        address tokenAddress,
        uint256 tokenAmount,
        bytes32 documentHash,
        bool locked
    ) {
        return (
            pledge.tokenAddress,
            pledge.tokenAmount,
            pledge.documentHash,
            pledge.locked
        );
    }

    /**
     * @dev Get repayment details
     * @param repaymentId ID of the repayment
     * @return amount The basic repayment amount
     * @return penalty The additional penalty amount (if any)
     * @return dueDate The due date for the repayment
     * @return paidDate The date when repayment was made (0 if not paid)
     * @return paid Whether the repayment has been paid
     */
    function getRepaymentDetails(uint256 repaymentId) external view returns (
        uint256 amount,
        uint256 penalty,
        uint256 dueDate,
        uint256 paidDate,
        bool paid
    ) {
        require(repaymentId < loan.totalRepayments, "Invalid repayment ID");
        Repayment storage repayment = repayments[repaymentId];
        
        return (
            repayment.amount,
            repayment.penalty,
            repayment.dueDate,
            repayment.paidDate,
            repayment.paid
        );
    }

    /**
     * @dev Get current vote details
     * @return startTime The start time of the vote
     * @return endTime The end time of the vote
     * @return votesFor The number of votes for expropriation
     * @return votesAgainst The number of votes against expropriation
     * @return status The current status of the vote
     * @return approved Whether the expropriation was approved
     */
    function getCurrentVoteDetails() external view returns (
        uint256 startTime,
        uint256 endTime,
        uint256 votesFor,
        uint256 votesAgainst,
        VoteStatus status,
        bool approved
    ) {
        return (
            currentVote.startTime,
            currentVote.endTime,
            currentVote.votesFor,
            currentVote.votesAgainst,
            currentVote.status,
            currentVote.expropriationApproved
        );
    }

    /**
     * @dev Check if a repayment is late and eligible for expropriation vote
     * @param repaymentId ID of the repayment to check
     * @return isLate Whether the repayment is late
     * @return isEligibleForVote Whether the repayment is eligible for an expropriation vote
     * @return daysLate Number of days the repayment is late
     */
    function checkRepaymentStatus(uint256 repaymentId) external view returns (
        bool isLate,
        bool isEligibleForVote,
        uint256 daysLate
    ) {
        require(repaymentId < loan.totalRepayments, "Invalid repayment ID");
        
        Repayment storage repayment = repayments[repaymentId];
        
        if (repayment.paid || repayment.dueDate == 0) {
            return (false, false, 0);
        }
        
        if (block.timestamp <= repayment.dueDate) {
            return (false, false, 0);
        }
        
        daysLate = (block.timestamp - repayment.dueDate) / (1 days);
        isLate = daysLate > 0;
        isEligibleForVote = block.timestamp > repayment.dueDate + LATE_PAYMENT_THRESHOLD;
        
        return (isLate, isEligibleForVote, daysLate);
    }
 }


// pragma solidity ^0.8.0;

// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// import "@openzeppelin/contracts/access/AccessControl.sol";
// import "@openzeppelin/contracts/utils/Pausable.sol";
// import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
// import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
// import "./IdentitySoulboundToken.sol";
// import "./GovToken.sol";

// /**
//  * @title LoanCrowdfunding
//  * @dev A contract for managing loan-based crowdfunding with pledged collateral,
//  * periodic repayments, and governance voting for late payments.
//  * Enhanced with identity verification using Soulbound Tokens.
//  */
// contract LoanCrowdfunding is ReentrancyGuard, AccessControl, Pausable {
//     using SafeERC20 for IERC20;
//     using ECDSA for bytes32;

//     // Roles
//     bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
//     bytes32 public constant CLIENT_ROLE = keccak256("CLIENT_ROLE");

//     // Enums
//     enum LoanStatus { 
//         Inactive,
//         PledgeSubmitted,
//         InvestmentActive,
//         FundingSuccessful,
//         FundingFailed,
//         FundsWithdrawn,
//         InRepayment,
//         Completed,
//         Defaulted 
//     }
    
//     enum VoteStatus { 
//         NotStarted,
//         Active,
//         Completed 
//     }

//     // Structs - Packed for gas efficiency
//     struct Pledge {
//         address tokenAddress;    // Address of the token used as collateral
//         uint128 tokenAmount;     // Amount of tokens pledged - 128 bits is plenty (> 10^38)
//         bytes32 documentHash;    // Hash of the pledge document
//         bool locked;             // Whether the pledge is locked
//     }

//     struct Loan {
//         uint128 targetAmount;        // Target funding amount
//         uint128 totalFunded;         // Total amount funded
//         uint128 remainingBalance;    // Remaining loan balance to be repaid
//         uint64 investmentPeriod;     // End time for investments
//         uint64 withdrawalDeadline;   // Deadline for client to withdraw funds
//         uint64 repaymentInterval;    // Interval between repayments in seconds
//         uint32 interestRate;         // Annual interest rate (basis points)
//         uint64 nextRepaymentDate;    // Timestamp for next repayment
//         uint16 totalRepayments;      // Total number of repayments
//         uint16 completedRepayments;  // Number of completed repayments
//         uint32 riskRating;           // Risk rating (1-100)
//         string jurisdiction;         // Legal jurisdiction for this loan
//     }

//     struct Repayment {
//         uint128 amount;          // Basic repayment amount
//         uint128 penalty;         // Additional penalty amount
//         uint64 dueDate;          // Due date for the repayment
//         uint64 paidDate;         // Date when repayment was made
//         bool paid;               // Whether repayment has been paid
//     }

//     struct Vote {
//         uint64 startTime;        // Start time of vote
//         uint64 endTime;          // End time of vote
//         uint128 votesFor;        // Votes for expropriation
//         uint128 votesAgainst;    // Votes against expropriation
//         VoteStatus status;       // Current status of the vote
//         bool expropriationApproved; // Result of vote
//     }

//     // Immutable state variables
//     address public immutable client;
//     IERC20 public immutable stablecoin;
//     GovToken public immutable govToken;
//     IdentitySoulboundToken public immutable identityToken;
    
//     // Constants
//     uint256 public constant LATE_PAYMENT_THRESHOLD = 90 days; // 3 months
//     uint256 public constant WITHDRAW_PERIOD = 3 days; // 3 working days
//     uint256 public constant VOTING_PERIOD = 7 days;
//     uint256 public constant MIN_VOTE_PARTICIPATION = 30; // 30% participation required
//     uint256 public constant EXPROPRIATION_THRESHOLD = 51; // 51% for expropriation
//     uint256 public constant MAX_REPAYMENTS = 60; // Safety cap on repayments

//     // State variables
//     LoanStatus public loanStatus;
//     Pledge public pledge;
//     Loan public loan;
//     Vote public currentVote;
//     bool private _initialized; // Prevents double initialization
//     uint32 public minCreditScore; // Minimum credit score for investors
    
//     // Mappings
//     mapping(address => uint256) public investments;
//     mapping(address => bool) public hasClaimedGovTokens;
//     mapping(address => bool) public hasClaimedRefund;
//     mapping(uint256 => Repayment) public repayments;
//     mapping(address => mapping(uint256 => bool)) public investorVoted;
//     mapping(uint256 => mapping(address => uint256)) public repaymentClaims;
//     mapping(address => uint256) public pledgeSharesClaimed; // Tracks claimed shares to avoid double claims

//     // Events
//     event PledgeSubmitted(address indexed tokenAddress, uint256 amount, bytes32 documentHash);
//     event PledgeLocked(address indexed tokenAddress, uint256 amount);
//     event PledgeUnlocked(address indexed tokenAddress, uint256 amount);
//     event PledgeWithdrawn(address indexed recipient, address tokenAddress, uint256 amount);
//     event InvestmentReceived(address indexed investor, uint256 amount, uint256 timestamp);
//     event FundingSuccessful(uint256 totalFunded);
//     event FundingFailed(uint256 totalFunded);
//     event FundsWithdrawn(address indexed client, uint256 amount);
//     event GovTokensClaimed(address indexed investor, uint256 amount);
//     event RefundClaimed(address indexed investor, uint256 amount);
//     event RepaymentScheduled(uint256 indexed repaymentId, uint256 amount, uint256 dueDate);
//     event RepaymentReceived(uint256 indexed repaymentId, uint256 amount, uint256 penalty);
//     event RepaymentProfit(address indexed investor, uint256 repaymentId, uint256 amount);
//     event VoteStarted(uint256 repaymentId, uint256 startTime, uint256 endTime);
//     event VoteCast(address indexed voter, bool support, uint256 weight);
//     event VoteCompleted(bool expropriationApproved, uint256 votesFor, uint256 votesAgainst);
//     event LoanCompleted();
//     event LoanDefaulted();
//     event PenaltyCalculated(uint256 indexed repaymentId, uint256 penalty, uint256 weeksLate);
//     event EmergencyPaused(address indexed by);
//     event EmergencyUnpaused(address indexed by);
//     event InvestorVerified(address indexed investor, uint256 tokenId);
//     event ClientVerified(address indexed client);
//     event RiskRatingUpdated(uint32 newRating);
//     event InvestmentLimitReached(address indexed investor, uint256 amount, uint256 limit);

//     // Modifiers
//     modifier onlyVerifiedClient() {
//         (bool isVerified, , , , , ) = identityToken.checkVerification(
//             msg.sender, 
//             address(this),
//             IdentitySoulboundToken.ParticipantType.Client
//         );
//         require(isVerified, "Not a verified client");
//         require(msg.sender == client, "Not the loan client");
//         _;
//     }

//     modifier onlyVerifiedInvestor() {
//         (bool isVerified, , , , , ) = identityToken.checkVerification(
//             msg.sender, 
//             address(this),
//             IdentitySoulboundToken.ParticipantType.Investor
//         );
//         require(isVerified, "Not a verified investor");
//         _;
//     }

//     modifier onlyVerifiedAuditor() {
//         (bool isVerified, , , , , ) = identityToken.checkVerification(
//             msg.sender, 
//             address(this),
//             IdentitySoulboundToken.ParticipantType.Auditor
//         );
//         require(isVerified, "Not a verified auditor");
//         require(hasRole(AUDITOR_ROLE, msg.sender), "Not an auditor");
//         _;
//     }

//     modifier onlyInvestor() {
//         require(investments[msg.sender] > 0, "Only investors can call this function");
//         _;
//     }

//     modifier atStatus(LoanStatus _status) {
//         require(loanStatus == _status, "Invalid loan status for this action");
//         _;
//     }

//     modifier notInitialized() {
//         require(!_initialized, "Contract already initialized");
//         _;
//     }

//     /**
//      * @dev Constructor that initializes all immutable variables
//      * @param _client Address of the client (borrower)
//      * @param _stablecoin Address of the stablecoin contract
//      * @param _identityToken Address of the IdentitySoulboundToken contract
//      */
//     constructor(
//         address _client,
//         address _stablecoin,
//         address _identityToken
//     ) {
//         require(_client != address(0), "Client cannot be zero address");
//         require(_stablecoin != address(0), "Stablecoin cannot be zero address");
//         require(_identityToken != address(0), "Identity token cannot be zero address");
        
//         // Verify client has a valid soulbound token
//         IdentitySoulboundToken iToken = IdentitySoulboundToken(_identityToken);
//         (bool isVerified, , , , , ) = iToken.checkVerification(
//             _client,
//             address(this),
//             IdentitySoulboundToken.ParticipantType.Client
//         );
//         // require(isVerified, "Client must have a valid SBT verification"); 
//         require(true, "Client must have a valid SBT verification"); //just for testing assume it is ture. then remove it and uncomment the line above
        
//         // Set up roles
//         _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
//         _grantRole(AUDITOR_ROLE, msg.sender);
//         _grantRole(CLIENT_ROLE, _client);
        
//         client = _client;
//         stablecoin = IERC20(_stablecoin);
//         identityToken = iToken;
        
//         // Deploy the governance token
//         govToken = new GovToken();
//         // Grant this contract the minter role
//         govToken.grantRole(govToken.MINTER_ROLE(), address(this));
        
//         loanStatus = LoanStatus.Inactive;
//         minCreditScore = 0; // Default no minimum
//     }

//     /**
//      * @dev Set the minimum credit score required for investors
//      * @param _minCreditScore The minimum score (0-100)
//      */
//     function setMinCreditScore(uint32 _minCreditScore) external onlyRole(DEFAULT_ADMIN_ROLE) {
//         require(_minCreditScore <= 100, "Score must be 0-100");
//         minCreditScore = _minCreditScore;
//     }

//     /**
//      * @dev Initialize the loan contract with all necessary parameters
//      * @param _targetAmount The target funding amount
//      * @param _investmentPeriod End time for investments (in seconds from now)
//      * @param _repaymentInterval Time between repayments (in seconds)
//      * @param _totalRepayments Total number of repayments
//      * @param _interestRate Annual interest rate (in basis points, e.g., 1000 = 10%)
//      * @param _riskRating Risk rating for the loan (1-100)
//      * @param _jurisdiction Jurisdiction code for this loan
//      */
//     function initialize(
//         uint256 _targetAmount,
//         uint256 _investmentPeriod,
//         uint256 _repaymentInterval,
//         uint256 _totalRepayments,
//         uint256 _interestRate,
//         uint32 _riskRating,
//         string calldata _jurisdiction
//     ) external onlyVerifiedAuditor notInitialized {
//         require(_targetAmount > 0 && _targetAmount <= type(uint128).max, "Invalid target amount");
//         require(_investmentPeriod > 0, "Investment period must be in the future");
//         require(_repaymentInterval > 0, "Repayment interval must be greater than zero");
//         require(_totalRepayments > 0 && _totalRepayments <= MAX_REPAYMENTS, "Invalid repayment count");
//         require(_interestRate <= 10000, "Interest rate cannot exceed 100%"); // 10000 basis points = 100%
//         require(_riskRating > 0 && _riskRating <= 100, "Risk rating must be 1-100");
//         require(bytes(_jurisdiction).length > 0, "Jurisdiction cannot be empty");
        
//         loan = Loan({
//             targetAmount: uint128(_targetAmount),
//             investmentPeriod: uint64(block.timestamp + _investmentPeriod),
//             withdrawalDeadline: 0, // Will be set once funding is successful
//             totalFunded: 0,
//             remainingBalance: uint128(_targetAmount),
//             repaymentInterval: uint64(_repaymentInterval),
//             interestRate: uint32(_interestRate),
//             nextRepaymentDate: 0, // Will be set once client withdraws funds
//             totalRepayments: uint16(_totalRepayments),
//             completedRepayments: 0,
//             riskRating: _riskRating,
//             jurisdiction: _jurisdiction
//         });
        
//         // Calculate repayment amounts
//         uint256 totalInterest = (_targetAmount * _interestRate * _totalRepayments * _repaymentInterval) / (10000 * 365 days);
//         uint256 totalToRepay = _targetAmount + totalInterest;
//         uint256 repaymentAmount = totalToRepay / _totalRepayments;
        
//         // Schedule repayments
//         for (uint256 i = 0; i < _totalRepayments; i++) {
//             repayments[i] = Repayment({
//                 amount: uint128(repaymentAmount),
//                 penalty: 0,
//                 dueDate: 0, // Will be set once client withdraws funds
//                 paidDate: 0,
//                 paid: false
//             });
            
//             emit RepaymentScheduled(i, repaymentAmount, 0);
//         }
        
//         loanStatus = LoanStatus.PledgeSubmitted;
//         _initialized = true;
        
//         emit RiskRatingUpdated(_riskRating);
//     }

//     /**
//      * @dev Emergency pause - halts critical contract operations
//      */
//     function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
//         _pause();
//         emit EmergencyPaused(msg.sender);
//     }

//     /**
//      * @dev Resume contract operations after pause
//      */
//     function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
//         _unpause();
//         emit EmergencyUnpaused(msg.sender);
//     }

//     /**
//      * @dev Submit pledge as collateral
//      * @param tokenAddress Address of the token to pledge
//      * @param amount Amount of tokens to pledge
//      * @param documentHash Hash of the pledge document
//      */
//     function submitPledge(
//         address tokenAddress,
//         uint256 amount,
//         bytes32 documentHash
//     ) external onlyVerifiedClient atStatus(LoanStatus.PledgeSubmitted) whenNotPaused {
//         require(amount > 0 && amount <= type(uint128).max, "Invalid pledge amount");
//         require(documentHash != bytes32(0), "Document hash cannot be empty");
//         require(IERC20(tokenAddress).allowance(client, address(this)) >= amount, "Allowance too low");
        
//         // Security check to prevent token manipulation
//         uint256 balanceBefore = IERC20(tokenAddress).balanceOf(address(this));
        
//         // Transfer tokens to contract
//         IERC20(tokenAddress).safeTransferFrom(client, address(this), amount);
        
//         // Verify the actual amount received
//         uint256 balanceAfter = IERC20(tokenAddress).balanceOf(address(this));
//         uint256 actualAmount = balanceAfter - balanceBefore;
//         require(actualAmount > 0, "No tokens received");
        
//         // Set pledge details
//         pledge = Pledge({
//             tokenAddress: tokenAddress,
//             tokenAmount: uint128(actualAmount),
//             documentHash: documentHash,
//             locked: true
//         });
        
//         // Update status to start investment period
//         loanStatus = LoanStatus.InvestmentActive;
        
//         emit PledgeSubmitted(tokenAddress, actualAmount, documentHash);
//         emit PledgeLocked(tokenAddress, actualAmount);
//     }

//     /**
//      * @dev Invest in the loan
//      * @param amount Amount to invest
//      * @return success True if investment was successful
//      */
//     function invest(uint256 amount) external nonReentrant whenNotPaused onlyVerifiedInvestor atStatus(LoanStatus.InvestmentActive) returns (bool success) {
//         require(amount > 0, "Investment amount must be greater than zero");
//         require(block.timestamp <= loan.investmentPeriod, "Investment period has ended");
        
//         // Verify investor's eligibility
//         (bool isVerified, uint256 tokenId, , , uint32 investmentLimit, IdentitySoulboundToken.AccreditationStatus accreditation) = 
//             identityToken.checkVerification(
//                 msg.sender,
//                 address(this),
//                 IdentitySoulboundToken.ParticipantType.Investor
//             );
            
//         require(isVerified, "Not a verified investor");
        
//         // Check risk tolerance compatibility with loan risk
//         // This is simplified - in a real system you'd have more sophisticated checks
//         if (loan.riskRating > 70) {
//             // High risk loans require more than non-accredited investors
//             require(
//                 accreditation == IdentitySoulboundToken.AccreditationStatus.AccreditedIndividual || 
//                 accreditation == IdentitySoulboundToken.AccreditationStatus.InstitutionalInvestor,
//                 "Loan risk too high for non-accredited investors"
//             );
//         }
         
//         // Check investment limit
//         if (investmentLimit > 0) {
//             uint256 alreadyInvested = investments[msg.sender];
//             require(alreadyInvested + amount <= investmentLimit, "Would exceed your investment limit");
//         }
        
//         // Check if funding target would be exceeded
//         uint256 newTotal = uint256(loan.totalFunded) + amount;
//         require(newTotal <= loan.targetAmount, "Investment would exceed target amount");
        
//         require(stablecoin.allowance(msg.sender, address(this)) >= amount, "Allowance too low");
        
//         // Update state before external call
//         investments[msg.sender] += amount;
//         loan.totalFunded = uint128(newTotal);
        
//         // Transfer stablecoins to contract
//         uint256 balanceBefore = stablecoin.balanceOf(address(this));
//         stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        
//         // Verify the actual amount received
//         uint256 balanceAfter = stablecoin.balanceOf(address(this));
//         uint256 actualAmount = balanceAfter - balanceBefore;
        
//         // If actual amount is different from expected, adjust investment records
//         if (actualAmount != amount) {
//             investments[msg.sender] = investments[msg.sender] - amount + actualAmount;
//             loan.totalFunded = uint128(uint256(loan.totalFunded) - amount + actualAmount);
//             amount = actualAmount;
//         }
        
//         emit InvestmentReceived(msg.sender, amount, block.timestamp);
//         emit InvestorVerified(msg.sender, tokenId);
        
//         // Check if target is reached
//         if (loan.totalFunded >= loan.targetAmount) {
//             loanStatus = LoanStatus.FundingSuccessful;
//             loan.withdrawalDeadline = uint64(block.timestamp + WITHDRAW_PERIOD);
//             emit FundingSuccessful(loan.totalFunded);
//         }
        
//         return true;
//     }

//     /**
//      * @dev Update funding status after investment period ends
//      */
//     function updateFundingStatus() external whenNotPaused {
//         require(loanStatus == LoanStatus.InvestmentActive, "Loan is not in active investment state");
//         require(block.timestamp > loan.investmentPeriod, "Investment period has not ended yet");
        
//         if (loan.totalFunded < loan.targetAmount) {
//             loanStatus = LoanStatus.FundingFailed;
//             emit FundingFailed(loan.totalFunded);
//         } else {
//             loanStatus = LoanStatus.FundingSuccessful;
//             loan.withdrawalDeadline = uint64(block.timestamp + WITHDRAW_PERIOD);
//             emit FundingSuccessful(loan.totalFunded);
//         }
//     }

//     /**
//      * @dev Claim GOV tokens for investors
//      */
//     function claimGovTokens() external nonReentrant whenNotPaused onlyVerifiedInvestor onlyInvestor {
//         require(
//             loanStatus == LoanStatus.FundingSuccessful || 
//             loanStatus == LoanStatus.FundsWithdrawn || 
//             loanStatus == LoanStatus.InRepayment, 
//             "Funding must be successful to claim tokens"
//         );
//         require(!hasClaimedGovTokens[msg.sender], "GOV tokens already claimed");
        
//         uint256 amount = investments[msg.sender];
//         hasClaimedGovTokens[msg.sender] = true;
        
//         // Mint GOV tokens to investor
//         govToken.mint(msg.sender, amount);
        
//         emit GovTokensClaimed(msg.sender, amount);
//     }

//     /**
//      * @dev Withdraw funds by client
//      */
//     function withdrawFunds() external nonReentrant whenNotPaused onlyVerifiedClient atStatus(LoanStatus.FundingSuccessful) {
//         require(block.timestamp <= loan.withdrawalDeadline, "Withdrawal period has expired");
        
//         // Update status
//         loanStatus = LoanStatus.FundsWithdrawn;
        
//         // Set repayment schedule
//         uint256 nextDate = block.timestamp;
//         for (uint256 i = 0; i < loan.totalRepayments; i++) {
//             nextDate += loan.repaymentInterval;
//             repayments[i].dueDate = uint64(nextDate);
            
//             emit RepaymentScheduled(i, repayments[i].amount, nextDate);
//         }
        
//         loan.nextRepaymentDate = uint64(repayments[0].dueDate);
//         loanStatus = LoanStatus.InRepayment;
        
//         // Get the amount to transfer
//         uint256 amountToTransfer = loan.totalFunded;
        
//         // Transfer funds to client
//         stablecoin.safeTransfer(client, amountToTransfer);
        
//         emit FundsWithdrawn(client, amountToTransfer);
//     }

//     /**
//      * @dev Claim refund if funding failed or client didn't withdraw
//      */
//     function claimRefund() external nonReentrant whenNotPaused onlyVerifiedInvestor onlyInvestor {
//         bool canClaim = false;
        
//         // Case 1: Funding failed
//         if (loanStatus == LoanStatus.FundingFailed) {
//             canClaim = true;
//         }
        
//         // Case 2: Client didn't withdraw in time
//         if (loanStatus == LoanStatus.FundingSuccessful && block.timestamp > loan.withdrawalDeadline) {
//             loanStatus = LoanStatus.FundingFailed;
//             emit FundingFailed(loan.totalFunded);
//             canClaim = true;
//         }
        
//         require(canClaim, "Not eligible for refund");
//         require(!hasClaimedRefund[msg.sender], "Refund already claimed");
//         require(investments[msg.sender] > 0, "No investment to refund");
        
//         uint256 amount = investments[msg.sender];
//         hasClaimedRefund[msg.sender] = true;
        
//         stablecoin.safeTransfer(msg.sender, amount);
        
//         emit RefundClaimed(msg.sender, amount);
//     }

//     /**
//      * @dev Unlock pledge if funding failed
//      */
//     function unlockPledge() external whenNotPaused onlyVerifiedClient {
//         require(loanStatus == LoanStatus.FundingFailed, "Funding has not failed");
//         require(pledge.locked, "Pledge already unlocked");
        
//         pledge.locked = false;
        
//         emit PledgeUnlocked(pledge.tokenAddress, pledge.tokenAmount);
//     }

//     /**
//      * @dev Withdraw pledge if unlocked
//      */
//     function withdrawPledge() external nonReentrant whenNotPaused onlyVerifiedClient {
//         require(!pledge.locked, "Pledge is still locked");
//         require(pledge.tokenAmount > 0, "No pledge to withdraw");
        
//         address tokenAddress = pledge.tokenAddress;
//         uint256 amount = pledge.tokenAmount;
        
//         // Reset pledge amount first to prevent reentrancy
//         pledge.tokenAmount = 0;
        
//         // Transfer tokens back to client
//         IERC20(tokenAddress).safeTransfer(client, amount);
        
//         emit PledgeWithdrawn(client, tokenAddress, amount);
        
//         // If loan is completed and pledge withdrawn, mark as fully completed
//         if (loanStatus == LoanStatus.Completed) {
//             emit LoanCompleted();
//         }
//     }

//     /**
//      * @dev Calculate penalty for late repayment
//      * @param dueDate The repayment due date
//      * @param repaymentAmount The base repayment amount
//      * @return penalty The calculated penalty amount
//      * @return weeksLate Number of weeks the payment is late
//      */
//     function _calculatePenalty(uint64 dueDate, uint128 repaymentAmount) internal view returns (uint128 penalty, uint256 weeksLate) {
//         if (block.timestamp <= dueDate) {
//             return (0, 0);
//         }
        
//         // Calculate weeks late (1% penalty per week)
//         weeksLate = (block.timestamp - dueDate) / (7 days);
//         if (weeksLate > 0) {
//             // Cap penalty at 50% of repayment to prevent excessive penalties
//             uint256 calculatedPenalty = (uint256(repaymentAmount) * weeksLate) / 100;
//             uint256 maxPenalty = uint256(repaymentAmount) / 2; // 50%
//             penalty = uint128(calculatedPenalty > maxPenalty ? maxPenalty : calculatedPenalty);
//         }
        
//         return (penalty, weeksLate);
//     }

//     /**
//      * @dev Make a repayment
//      * @param repaymentId ID of the repayment
//      */
//     function makeRepayment(uint256 repaymentId) external nonReentrant whenNotPaused onlyVerifiedClient atStatus(LoanStatus.InRepayment) {
//         require(repaymentId < loan.totalRepayments, "Invalid repayment ID");
//         require(!repayments[repaymentId].paid, "Repayment already made");
        
//         Repayment storage repayment = repayments[repaymentId];
        
//         // Calculate penalty if late
//         (uint128 penalty, uint256 weeksLate) = _calculatePenalty(repayment.dueDate, repayment.amount);
//         repayment.penalty = penalty;
        
//         if (penalty > 0) {
//             emit PenaltyCalculated(repaymentId, penalty, weeksLate);
//         }
        
//         uint256 totalAmount = uint256(repayment.amount) + uint256(penalty);
        
//         // Ensure sufficient allowance and balance
//         require(stablecoin.allowance(client, address(this)) >= totalAmount, "Allowance too low");
        
//         // Update repayment state before external calls
//         repayment.paid = true;
//         repayment.paidDate = uint64(block.timestamp);
        
//         // Update loan state
//         loan.remainingBalance = uint128(uint256(loan.remainingBalance) - uint256(repayment.amount));
//         loan.completedRepayments++;
        
//         // Transfer repayment to contract
//         stablecoin.safeTransferFrom(client, address(this), totalAmount);
        
//         emit RepaymentReceived(repaymentId, repayment.amount, penalty);
        
//         // Update next repayment date if there are more repayments
//         if (loan.completedRepayments < loan.totalRepayments) {
//             loan.nextRepaymentDate = repayments[repaymentId + 1].dueDate;
//         } else {
//             // All repayments completed
//             loanStatus = LoanStatus.Completed;
//             pledge.locked = false;
//             emit PledgeUnlocked(pledge.tokenAddress, pledge.tokenAmount);
//         }
//     }

//     /**
//      * @dev Claim repayment profit as an investor
//      * @param repaymentId ID of the repayment
//      */
//     function claimRepaymentProfit(uint256 repaymentId) external nonReentrant whenNotPaused onlyVerifiedInvestor onlyInvestor {
//         require(repaymentId < loan.totalRepayments, "Invalid repayment ID");
//         require(repayments[repaymentId].paid, "Repayment not made yet");
//         require(repaymentClaims[repaymentId][msg.sender] == 0, "Already claimed profit for this repayment");
        
//         Repayment storage repayment = repayments[repaymentId];
        
//         // Calculate investor's share based on their investment percentage
//         uint256 totalAmount = uint256(repayment.amount) + uint256(repayment.penalty);
//         uint256 investorShare = (investments[msg.sender] * totalAmount) / uint256(loan.totalFunded);
        
//         // Record claim to prevent double claiming
//         repaymentClaims[repaymentId][msg.sender] = investorShare;
        
//         // Transfer profit to investor
//         stablecoin.safeTransfer(msg.sender, investorShare);
        
//         emit RepaymentProfit(msg.sender, repaymentId, investorShare);
//     }

//     /**
//      * @dev Start a vote for expropriation due to late payment
//      * @param repaymentId ID of the late repayment
//      */
//     function startExpropriationVote(uint256 repaymentId) external whenNotPaused onlyVerifiedInvestor onlyInvestor atStatus(LoanStatus.InRepayment) {
//         require(repaymentId < loan.totalRepayments, "Invalid repayment ID");
//         require(!repayments[repaymentId].paid, "Repayment already made");
//         require(
//             block.timestamp > repayments[repaymentId].dueDate + LATE_PAYMENT_THRESHOLD, 
//             "Payment not late enough"
//         );
//         require(
//             currentVote.status == VoteStatus.NotStarted || 
//             currentVote.status == VoteStatus.Completed, 
//             "Vote already in progress"
//         );
        
//         // Initialize vote
//         currentVote = Vote({
//             startTime: uint64(block.timestamp),
//             endTime: uint64(block.timestamp + VOTING_PERIOD),
//             votesFor: 0,
//             votesAgainst: 0,
//             status: VoteStatus.Active,
//             expropriationApproved: false
//         });
        
//         emit VoteStarted(repaymentId, currentVote.startTime, currentVote.endTime);
//     }

//     /**
//      * @dev Cast a vote on expropriation
//      * @param support True to vote for expropriation, false to vote against
//      */
//     function vote(bool support) external whenNotPaused onlyVerifiedInvestor onlyInvestor {
//         require(currentVote.status == VoteStatus.Active, "No active vote");
//         require(block.timestamp <= currentVote.endTime, "Voting period ended");
//         require(!investorVoted[msg.sender][currentVote.startTime], "Already voted");
        
//         // Mark as voted
//         investorVoted[msg.sender][currentVote.startTime] = true;
        
//         // Count vote based on GOV token balance
//         uint256 voteWeight = govToken.balanceOf(msg.sender);
//         require(voteWeight > 0, "No voting power");
        
//         if (support) {
//             // Check for overflow before adding
//             require(uint256(currentVote.votesFor) + voteWeight <= type(uint128).max, "Vote count overflow");
//             currentVote.votesFor += uint128(voteWeight);
//         } else {
//             // Check for overflow before adding
//             require(uint256(currentVote.votesAgainst) + voteWeight <= type(uint128).max, "Vote count overflow");
//             currentVote.votesAgainst += uint128(voteWeight);
//         }
        
//         emit VoteCast(msg.sender, support, voteWeight);
//     }

//     /**
//      * @dev Finalize the vote and determine outcome
//      */
//     function finalizeVote() external whenNotPaused {
//         require(currentVote.status == VoteStatus.Active, "No active vote");
//         require(block.timestamp > currentVote.endTime, "Voting period not ended");
        
//         // Calculate total votes and participation
//         uint256 totalVotes = uint256(currentVote.votesFor) + uint256(currentVote.votesAgainst);
//         uint256 totalGovTokens = govToken.totalSupply();
        
//         // Prevent division by zero
//         require(totalGovTokens > 0, "No governance tokens issued");
        
//         uint256 participationRate = (totalVotes * 100) / totalGovTokens;
        
//         // Check if quorum is reached
//         bool quorumReached = participationRate >= MIN_VOTE_PARTICIPATION;
        
//         // Determine outcome
//         bool expropriationApproved = false;
//         if (quorumReached && totalVotes > 0) {
//             uint256 approvalRate = (uint256(currentVote.votesFor) * 100) / totalVotes;
//             expropriationApproved = approvalRate >= EXPROPRIATION_THRESHOLD;
//         }
        
//         // Update vote status
//         currentVote.status = VoteStatus.Completed;
//         currentVote.expropriationApproved = expropriationApproved;
        
//         if (expropriationApproved) {
//             // Handle loan default
//             loanStatus = LoanStatus.Defaulted;
//             emit LoanDefaulted();
//         }
        
//         emit VoteCompleted(expropriationApproved, currentVote.votesFor, currentVote.votesAgainst);
//     }

//     /**
//      * @dev Claim pledge after loan default (only investors)
//      */
//     function claimPledgeShare() external nonReentrant whenNotPaused onlyVerifiedInvestor onlyInvestor {
//         require(loanStatus == LoanStatus.Defaulted, "Loan not defaulted");
//         require(pledge.tokenAmount > 0, "No pledge to claim");
        
//         uint256 investorAmount = investments[msg.sender];
//         require(investorAmount > pledgeSharesClaimed[msg.sender], "Already claimed maximum share");
        
//         // Calculate investor's share of the pledge
//         uint256 remainingShare = investorAmount - pledgeSharesClaimed[msg.sender];
//         uint256 investorShare = (remainingShare * uint256(pledge.tokenAmount)) / uint256(loan.totalFunded);
        
//         // Ensure investor hasn't already claimed
//         require(investorShare > 0, "No share to claim");
        
//         // Update claim record to prevent double claiming
//         pledgeSharesClaimed[msg.sender] += remainingShare;
        
//         // Update pledge amount
//         uint256 newPledgeAmount = uint256(pledge.tokenAmount) - investorShare;
//         require(newPledgeAmount <= type(uint128).max, "Pledge amount overflow");
//         pledge.tokenAmount = uint128(newPledgeAmount);
        
//         // Transfer pledge tokens to investor
//         IERC20(pledge.tokenAddress).safeTransfer(msg.sender, investorShare);
        
//         emit PledgeWithdrawn(msg.sender, pledge.tokenAddress, investorShare);
//     }

//     /**
//      * @dev Check if a caller is a verified investor
//      * @param investor Address to check
//      * @return isVerified Whether the address is a verified investor
//      * @return investmentLimit Maximum investment amount in USD
//      * @return accreditationStatus Accreditation status
//      */
//     function checkInvestorStatus(address investor) external view returns (
//         bool isVerified,
//         uint256 investmentLimit,
//         IdentitySoulboundToken.AccreditationStatus accreditationStatus
//     ) {
//         (bool verified, , , , uint32 limit, IdentitySoulboundToken.AccreditationStatus status) = 
//             identityToken.checkVerification(
//                 investor, 
//                 address(this),
//                 IdentitySoulboundToken.ParticipantType.Investor
//             );
            
//         return (verified, limit, status);
//     }

//     /**
//      * @dev Get loan details
//      * @return status The current status of the loan
//      * @return targetAmount The target funding amount
//      * @return totalFunded The total amount funded so far
//      * @return remainingBalance The remaining loan balance to be repaid
//      * @return nextRepaymentDate The timestamp for the next repayment
//      * @return completedRepayments The number of completed repayments
//      * @return totalRepayments The total number of repayments scheduled
//      * @return riskRating The risk rating of the loan (1-100)
//      * @return jurisdiction The legal jurisdiction for this loan
//      */
//     function getLoanDetails() external view returns (
//         LoanStatus status,
//         uint256 targetAmount,
//         uint256 totalFunded,
//         uint256 remainingBalance,
//         uint256 nextRepaymentDate,
//         uint256 completedRepayments,
//         uint256 totalRepayments,
//         uint32 riskRating,
//         string memory jurisdiction
//     ) {
//         return (
//             loanStatus,
//             loan.targetAmount,
//             loan.totalFunded,
//             loan.remainingBalance,
//             loan.nextRepaymentDate,
//             loan.completedRepayments,
//             loan.totalRepayments,
//             loan.riskRating,
//             loan.jurisdiction
//         );
//     }

//     /**
//      * @dev Get pledge details
//      * @return tokenAddress The address of the token used as collateral
//      * @return tokenAmount The amount of tokens pledged
//      * @return documentHash The hash of the pledge document
//      * @return locked Whether the pledge is currently locked
//      */
//     function getPledgeDetails() external view returns (
//         address tokenAddress,
//         uint256 tokenAmount,
//         bytes32 documentHash,
//         bool locked
//     ) {
//         return (
//             pledge.tokenAddress,
//             pledge.tokenAmount,
//             pledge.documentHash,
//             pledge.locked
//         );
//     }

//     /**
//      * @dev Get repayment details
//      * @param repaymentId ID of the repayment
//      * @return amount The basic repayment amount
//      * @return penalty The additional penalty amount (if any)
//      * @return dueDate The due date for the repayment
//      * @return paidDate The date when repayment was made (0 if not paid)
//      * @return paid Whether the repayment has been paid
//      */
//     function getRepaymentDetails(uint256 repaymentId) external view returns (
//         uint256 amount,
//         uint256 penalty,
//         uint256 dueDate,
//         uint256 paidDate,
//         bool paid
//     ) {
//         require(repaymentId < loan.totalRepayments, "Invalid repayment ID");
//         Repayment storage repayment = repayments[repaymentId];
        
//         return (
//             repayment.amount,
//             repayment.penalty,
//             repayment.dueDate,
//             repayment.paidDate,
//             repayment.paid
//         );
//     }

//     /**
//      * @dev Get current vote details
//      * @return startTime The start time of the vote
//      * @return endTime The end time of the vote
//      * @return votesFor The number of votes for expropriation
//      * @return votesAgainst The number of votes against expropriation
//      * @return status The current status of the vote
//      * @return approved Whether the expropriation was approved
//      */
//     function getCurrentVoteDetails() external view returns (
//         uint256 startTime,
//         uint256 endTime,
//         uint256 votesFor,
//         uint256 votesAgainst,
//         VoteStatus status,
//         bool approved
//     ) {
//         return (
//             currentVote.startTime,
//             currentVote.endTime,
//             currentVote.votesFor,
//             currentVote.votesAgainst,
//             currentVote.status,
//             currentVote.expropriationApproved
//         );
//     }

//     /**
//      * @dev Check if a repayment is late and eligible for expropriation vote
//      * @param repaymentId ID of the repayment to check
//      * @return isLate Whether the repayment is late
//      * @return isEligibleForVote Whether the repayment is eligible for an expropriation vote
//      * @return daysLate Number of days the repayment is late
//      */
//     function checkRepaymentStatus(uint256 repaymentId) external view returns (
//         bool isLate,
//         bool isEligibleForVote,
//         uint256 daysLate
//     ) {
//         require(repaymentId < loan.totalRepayments, "Invalid repayment ID");
        
//         Repayment storage repayment = repayments[repaymentId];
        
//         if (repayment.paid || repayment.dueDate == 0) {
//             return (false, false, 0);
//         }
        
//         if (block.timestamp <= repayment.dueDate) {
//             return (false, false, 0);
//         }
        
//         daysLate = (block.timestamp - repayment.dueDate) / (1 days);
//         isLate = daysLate > 0;
//         isEligibleForVote = block.timestamp > repayment.dueDate + LATE_PAYMENT_THRESHOLD;
        
//         return (isLate, isEligibleForVote, daysLate);
//     }
//  }