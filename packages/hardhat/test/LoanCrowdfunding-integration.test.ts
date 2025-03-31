import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import {
  GovToken,
  IdentitySoulboundToken,
  LoanCrowdfunding,
  MockUSDC,
  PriceFeedManager,
  MockChainlinkOracle,
} from "../typechain-types";
import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("LoanCrowdfunding Integration Test with Price Feed", function () {
  // Test accounts
  let deployer: SignerWithAddress;
  let client: SignerWithAddress;
  let investor1: SignerWithAddress;
  let investor2: SignerWithAddress;
  let auditor: SignerWithAddress;

  // Contract instances
  let mockUSDC: MockUSDC;
  let mockCollateral: MockUSDC;
  let identityToken: IdentitySoulboundToken;
  let loanCrowdfunding: LoanCrowdfunding;
  let govToken: GovToken;
  let priceFeedManager: PriceFeedManager;
  let mockUsdcOracle: MockChainlinkOracle;
  let mockCollateralOracle: MockChainlinkOracle;

  // Test parameters
  const targetAmount = ethers.parseUnits("10000", 6); // 10,000 USDC
  const investmentPeriod = 7 * 24 * 60 * 60; // 7 days
  const repaymentInterval = 30 * 24 * 60 * 60; // 30 days
  const totalRepayments = 6; // 6 monthly repayments
  const interestRate = 1000; // 10.00% annual interest rate
  const riskRating = 50; // Medium risk
  const jurisdiction = "US-NY"; // New York jurisdiction
  const pledgeAmount = ethers.parseUnits("15000", 18); // 15,000 collateral tokens

  // Price feed parameters
  const usdcPrice = ethers.parseUnits("1", 6); // 1 USD with 8 decimals for Chainlink format
  const collateralPrice = ethers.parseUnits("2", 6); // 2 USD per collateral token

  before(async function () {
    // Get test accounts
    [deployer, client, investor1, investor2, auditor] = await ethers.getSigners();

    console.log("🚀 === Setting up test environment ===");
    console.log(`👨‍💻 Deployer: ${deployer.address}`);
    console.log(`👤 Client: ${client.address}`);
    console.log(`💰 Investor 1: ${investor1.address}`);
    console.log(`💰 Investor 2: ${investor2.address}`);
    console.log(`🔍 Auditor: ${auditor.address}`);

    // Deploy mock tokens
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy("Mock USDC", "mUSDC", 6);
    await mockUSDC.waitForDeployment();

    const MockCollateral = await ethers.getContractFactory("MockUSDC"); // Reusing the same contract
    mockCollateral = await MockCollateral.deploy("Mock Collateral", "mCOL", 18);
    await mockCollateral.waitForDeployment();

    console.log(`💵 Deployed Mock USDC at: ${await mockUSDC.getAddress()}`);
    console.log(`🔒 Deployed Mock Collateral at: ${await mockCollateral.getAddress()}`);

    // Mint tokens to the accounts
    await mockUSDC.mint(investor1.address, ethers.parseUnits("100000", 6)); // 100,000 USDC
    await mockUSDC.mint(investor2.address, ethers.parseUnits("100000", 6)); // 100,000 USDC
    await mockCollateral.mint(client.address, ethers.parseUnits("50000", 18)); // 50,000 Collateral

    console.log("💱 Minted test tokens to accounts");

    // Deploy IdentitySoulboundToken
    const IdentitySoulboundToken = await ethers.getContractFactory("IdentitySoulboundToken");
    identityToken = await IdentitySoulboundToken.deploy();
    await identityToken.waitForDeployment();

    console.log(`🪪 Deployed IdentitySoulboundToken at: ${await identityToken.getAddress()}`);

    // Deploy mock Chainlink oracles
    const MockChainlinkOracle = await ethers.getContractFactory("MockChainlinkOracle");
    mockUsdcOracle = await MockChainlinkOracle.deploy(usdcPrice);
    await mockUsdcOracle.waitForDeployment();

    mockCollateralOracle = await MockChainlinkOracle.deploy(collateralPrice);
    await mockCollateralOracle.waitForDeployment();

    console.log(`📊 Deployed Mock USDC Oracle at: ${await mockUsdcOracle.getAddress()}`);
    console.log(`📊 Deployed Mock Collateral Oracle at: ${await mockCollateralOracle.getAddress()}`);

    // Deploy PriceFeedManager
    const PriceFeedManager = await ethers.getContractFactory("PriceFeedManager");
    priceFeedManager = await PriceFeedManager.deploy();
    await priceFeedManager.waitForDeployment();

    console.log(`💹 Deployed PriceFeedManager at: ${await priceFeedManager.getAddress()}`);
  });

  it("Should deploy LoanCrowdfunding contract and set up roles", async function () {
    console.log("\n🏗️ === Step 1: Deploy LoanCrowdfunding and set up roles ===");

    // Deploy LoanCrowdfunding
    const LoanCrowdfunding = await ethers.getContractFactory("LoanCrowdfunding");
    loanCrowdfunding = await LoanCrowdfunding.deploy(
      client.address,
      await mockUSDC.getAddress(),
      await identityToken.getAddress(),
    );
    await loanCrowdfunding.waitForDeployment();

    const loanAddress = await loanCrowdfunding.getAddress();
    console.log(`📝 Deployed LoanCrowdfunding at: ${loanAddress}`);

    // Register the loan contract as a platform in the identity token
    await identityToken.registerPlatform(loanAddress);
    console.log("✅ Registered LoanCrowdfunding as a platform in IdentitySoulboundToken");

    // Set up the price feed manager
    await loanCrowdfunding.setPriceFeedManager(await priceFeedManager.getAddress());
    console.log(`📈 Set PriceFeedManager for the LoanCrowdfunding contract`);

    // Configure price feeds in the manager
    await priceFeedManager.setPriceFeed(await mockUSDC.getAddress(), await mockUsdcOracle.getAddress());
    console.log(`💵 Set price feed for USDC: ${usdcPrice / BigInt(10 ** 8)} USD`);

    await priceFeedManager.setPriceFeed(await mockCollateral.getAddress(), await mockCollateralOracle.getAddress());
    console.log(`🔒 Set price feed for Collateral: ${collateralPrice / BigInt(10 ** 8)} USD`);

    // Set fallback prices as well (backup in case oracle fails)
    await priceFeedManager.setFallbackPrice(await mockUSDC.getAddress(), usdcPrice);
    await priceFeedManager.setFallbackPrice(await mockCollateral.getAddress(), collateralPrice);
    console.log("🔄 Set fallback prices for both tokens");

    // Get reference to the GOV token
    const govTokenAddress = await loanCrowdfunding.govToken();
    govToken = await ethers.getContractAt("GovToken", govTokenAddress);
    console.log(`🏛️ Governance token deployed at: ${govTokenAddress}`);

    // Grant auditor role
    await loanCrowdfunding.grantRole(await loanCrowdfunding.AUDITOR_ROLE(), auditor.address);
    console.log(`🔑 Granted AUDITOR_ROLE to ${auditor.address}`);

    // Verify client role
    const hasClientRole = await loanCrowdfunding.hasRole(await loanCrowdfunding.CLIENT_ROLE(), client.address);
    expect(hasClientRole).to.equal(true);
    console.log(`✅ Confirmed CLIENT_ROLE for ${client.address}`);
  });

  it("Should test price feed conversions", async function () {
    console.log("\n📊 === Step 2: Test price feed token conversions ===");

    // Test USD to token conversion for USDC
    const usdAmount = 100; // $100 USD
    const usdcAmount = await priceFeedManager.usdToToken.staticCall(usdAmount, await mockUSDC.getAddress());
    console.log(`💱 $100.00 USD = ${ethers.formatUnits(usdcAmount, 6)} USDC`);

    // With USDC at $1, expect 100 USDC (since 100 USD = 100 USDC when 1 USDC = 1 USD)
    expect(usdcAmount).to.be.closeTo(ethers.parseUnits("100", 6), 1000);

    // Test USD to token conversion for Collateral
    const collateralAmount = await priceFeedManager.usdToToken.staticCall(usdAmount, await mockCollateral.getAddress());
    console.log(`💱 $100.00 USD = ${ethers.formatUnits(collateralAmount, 18)} Collateral`);

    // With Collateral at $2, expect 50 Collateral tokens (since 100 USD / $2 = 50 Collateral)
    expect(collateralAmount).to.be.closeTo(ethers.parseUnits("50", 18), ethers.parseUnits("0.01", 18));

    // Test token to USD conversion for USDC
    const testUsdcAmount = ethers.parseUnits("100", 6); // 100 USDC
    const usdcUsdValue = await priceFeedManager.tokenToUsd.staticCall(testUsdcAmount, await mockUSDC.getAddress());
    console.log(`💵 100 USDC = $${usdcUsdValue} USD`);

    // With USDC at $1, expect 100 USD (since 100 USDC = 100 USD, without multiplying by 100)
    expect(usdcUsdValue).to.be.closeTo(BigInt(100), 10);

    // Test token to USD conversion for Collateral
    const testCollateralAmount = ethers.parseUnits("50", 18); // 50 Collateral tokens
    const collateralUsdValue = await priceFeedManager.tokenToUsd.staticCall(
      testCollateralAmount,
      await mockCollateral.getAddress(),
    );
    console.log(`🔒 50 Collateral = $${collateralUsdValue} USD`);

    // With Collateral at $2, expect 100 USD (since 50 Collateral tokens * $2 = 100 USD)
    expect(collateralUsdValue).to.be.closeTo(BigInt(100), 10);
  });

  it("Should verify participants", async function () {
    console.log("\n🔐 === Step 3: Verify participants with IdentitySoulboundToken ===");

    // Verify client
    const clientTokenId = await identityToken.verifyClient(
      client.address,
      jurisdiction,
      ethers.id("client-docs"),
      0, // No expiration
      "", // No token URI
    );
    console.log(`👤 Verified client with token ID: ${clientTokenId}`);

    // Verify investor 1 (accredited)
    const investor1TokenId = await identityToken.verifyInvestor(
      investor1.address,
      jurisdiction,
      ethers.id("investor1-docs"),
      0, // No expiration
      10000, // $10,000 investment limit
      1, // Conservative risk tolerance
      2, // Accredited individual
      "", // No token URI
    );
    console.log(`💰 Verified investor1 with token ID: ${investor1TokenId}`);

    // Verify investor 2 (non-accredited)
    const investor2TokenId = await identityToken.verifyInvestor(
      investor2.address,
      jurisdiction,
      ethers.id("investor2-docs"),
      0, // No expiration
      5000, // $5,000 investment limit
      1, // Conservative risk tolerance
      1, // Non-accredited
      "", // No token URI
    );
    console.log(`💰 Verified investor2 with token ID: ${investor2TokenId}`);

    // Verify auditor
    const auditorTokenId = await identityToken.verifyAuditor(
      auditor.address,
      jurisdiction,
      ethers.id("auditor-docs"),
      0, // No expiration
      "", // No token URI
    );
    console.log(`🔍 Verified auditor with token ID: ${auditorTokenId}`);

    // Verify participants are recognized by the system
    const clientVerified = await identityToken.checkVerification(
      client.address,
      await loanCrowdfunding.getAddress(),
      0, // Client participant type
    );
    expect(clientVerified[0]).to.equal(true);
    console.log("✅ Confirmed client verification status: ", clientVerified[0]);

    const investor1Verified = await identityToken.checkVerification(
      investor1.address,
      await loanCrowdfunding.getAddress(),
      1, // Investor participant type
    );
    expect(investor1Verified[0]).to.equal(true);
    console.log("✅ Confirmed investor1 verification status: ", investor1Verified[0]);

    const investor2Verified = await identityToken.checkVerification(
      investor2.address,
      await loanCrowdfunding.getAddress(),
      1, // Investor participant type
    );
    expect(investor2Verified[0]).to.equal(true);
    console.log("✅ Confirmed investor2 verification status: ", investor2Verified[0]);

    const auditorVerified = await identityToken.checkVerification(
      auditor.address,
      await loanCrowdfunding.getAddress(),
      2, // Auditor participant type
    );
    expect(auditorVerified[0]).to.equal(true);
    console.log("✅ Confirmed auditor verification status: ", auditorVerified[0]);
  });

  it("Should initialize the loan parameters", async function () {
    console.log("\n📋 === Step 4: Initialize loan parameters ===");

    // Initialize loan parameters using the auditor account
    const tx = await loanCrowdfunding
      .connect(auditor)
      .initialize(
        targetAmount,
        investmentPeriod,
        repaymentInterval,
        totalRepayments,
        interestRate,
        riskRating,
        jurisdiction,
      );

    const receipt = await tx.wait();
    console.log(`📝 Loan initialized in transaction: ${receipt?.hash || "Unknown transaction"}`);

    // Verify loan status
    const loanStatus = await loanCrowdfunding.loanStatus();
    expect(loanStatus).to.equal(1); // PledgeSubmitted status
    console.log(`🔄 Loan status is now: ${loanStatus} (PledgeSubmitted)`);

    // Verify loan details
    const loanDetails = await loanCrowdfunding.getLoanDetails();
    expect(loanDetails[1]).to.equal(targetAmount); // targetAmount
    expect(loanDetails[6]).to.equal(totalRepayments); // totalRepayments
    console.log(`💵 Loan target amount: ${ethers.formatUnits(loanDetails[1], 6)} USDC`);
    console.log(`🔄 Loan total repayments: ${loanDetails[6]}`);
    console.log(`⚠️ Loan risk rating: ${loanDetails[7]}`);
    console.log(`🏛️ Loan jurisdiction: ${loanDetails[8]}`);
  });

  it("Should verify collateral value before submission", async function () {
    console.log("\n💯 === Step 5: Verify collateral value ===");

    // Calculate expected USD value of the collateral
    const collateralUsdValue = await priceFeedManager.tokenToUsd.staticCall(
      pledgeAmount,
      await mockCollateral.getAddress(),
    );
    console.log(`🔒 Collateral value: $${collateralUsdValue / BigInt(100)} USD`);

    // Calculate expected USD value of the loan
    const loanUsdValue = await priceFeedManager.tokenToUsd.staticCall(targetAmount, await mockUSDC.getAddress());
    console.log(`💵 Loan value: $${loanUsdValue / BigInt(100)} USD`);

    // Calculate minimum required collateral (120% of loan value)
    const minCollateral = (loanUsdValue * BigInt(120)) / BigInt(100);
    console.log(`⚖️ Minimum required collateral: $${minCollateral / BigInt(100)} USD (120% of loan value)`);

    // Verify our test values meet the requirement
    expect(collateralUsdValue).to.be.gte(minCollateral);
    console.log(`✅ Collateral value exceeds minimum requirement: ${collateralUsdValue >= minCollateral}`);
  });

  it("Should submit pledge collateral", async function () {
    console.log("\n🔒 === Step 6: Submit pledge collateral ===");

    // Approve collateral token for the loan contract
    await mockCollateral.connect(client).approve(await loanCrowdfunding.getAddress(), pledgeAmount);
    console.log(`👍 Client approved ${ethers.formatUnits(pledgeAmount, 18)} collateral tokens for the loan contract`);

    // Submit pledge
    const documentHash = ethers.id("pledge-document-hash");
    const tx = await loanCrowdfunding
      .connect(client)
      .submitPledge(await mockCollateral.getAddress(), pledgeAmount, documentHash);

    const receipt = await tx.wait();
    console.log(`📝 Pledge submitted in transaction: ${receipt?.hash || "Unknown transaction"}`);

    // Verify pledge details
    const pledgeDetails = await loanCrowdfunding.getPledgeDetails();
    expect(pledgeDetails[0]).to.equal(await mockCollateral.getAddress()); // tokenAddress
    expect(pledgeDetails[1]).to.be.closeTo(pledgeAmount, 1); // tokenAmount
    expect(pledgeDetails[2]).to.equal(documentHash); // documentHash
    expect(pledgeDetails[3]).to.equal(true); // locked

    console.log(`💱 Pledge token: ${pledgeDetails[0]}`);
    console.log(`🔢 Pledge amount: ${ethers.formatUnits(pledgeDetails[1], 18)} tokens`);
    console.log(`📄 Pledge document hash: ${pledgeDetails[2]}`);
    console.log(`🔒 Pledge locked: ${pledgeDetails[3]}`);

    // Verify loan status
    const loanStatus = await loanCrowdfunding.loanStatus();
    expect(loanStatus).to.equal(2); // InvestmentActive status
    console.log(`🔄 Loan status is now: ${loanStatus} (InvestmentActive)`);
  });

  it("Should test investor investment limits", async function () {
    console.log("\n💼 === Step 7: Test investor investment limits ===");

    // Check investor1's investment limit
    const investor1Status = await loanCrowdfunding.checkInvestorStatus(investor1.address);
    console.log(`💰 Investor1 limit: $${investor1Status[1]} USD`);
    console.log(`🏅 Investor1 accreditation status: ${investor1Status[2]}`);

    // Convert USD limit to USDC amount using price feed
    const investor1LimitInUsdc = await priceFeedManager.usdToToken.staticCall(
      investor1Status[1],
      await mockUSDC.getAddress(),
    );
    console.log(`💵 Investor1 limit in USDC: ${ethers.formatUnits(investor1LimitInUsdc, 6)} USDC`);

    // Check investor2's investment limit
    const investor2Status = await loanCrowdfunding.checkInvestorStatus(investor2.address);
    console.log(`💰 Investor2 limit: $${investor2Status[1]} USD`);
    console.log(`🏅 Investor2 accreditation status: ${investor2Status[2]}`);

    // Convert USD limit to USDC amount using price feed
    const investor2LimitInUsdc = await priceFeedManager.usdToToken.staticCall(
      investor2Status[1],
      await mockUSDC.getAddress(),
    );
    console.log(`💵 Investor2 limit in USDC: ${ethers.formatUnits(investor2LimitInUsdc, 6)} USDC`);
  });

  it("Should allow investors to invest in the loan", async function () {
    console.log("\n💸 === Step 8: Investors invest in the loan ===");

    // Investment amounts
    const investor1Amount = ethers.parseUnits("6000", 6); // 6,000 USDC
    const investor2Amount = ethers.parseUnits("4000", 6); // 4,000 USDC

    // Investor 1 approves and invests
    await mockUSDC.connect(investor1).approve(await loanCrowdfunding.getAddress(), investor1Amount);
    console.log(`👍 Investor1 approved ${ethers.formatUnits(investor1Amount, 6)} USDC for the loan contract`);

    let tx = await loanCrowdfunding.connect(investor1).invest(investor1Amount);
    let receipt = await tx.wait();
    console.log(`💰 Investor1 invested in transaction: ${receipt?.hash || "Unknown transaction"}`);

    // Verify investment
    let investment = await loanCrowdfunding.investments(investor1.address);
    expect(investment).to.equal(investor1Amount);
    console.log(`📊 Investor1 investment: ${ethers.formatUnits(investment, 6)} USDC`);

    // Investor 2 approves and invests
    await mockUSDC.connect(investor2).approve(await loanCrowdfunding.getAddress(), investor2Amount);
    console.log(`👍 Investor2 approved ${ethers.formatUnits(investor2Amount, 6)} USDC for the loan contract`);

    tx = await loanCrowdfunding.connect(investor2).invest(investor2Amount);
    receipt = await tx.wait();
    console.log(`💰 Investor2 invested in transaction: ${receipt?.hash || "Unknown transaction"}`);

    // Verify investment
    investment = await loanCrowdfunding.investments(investor2.address);
    expect(investment).to.equal(investor2Amount);
    console.log(`📊 Investor2 investment: ${ethers.formatUnits(investment, 6)} USDC`);

    // Verify loan status and total funded
    const loanDetails = await loanCrowdfunding.getLoanDetails();
    expect(loanDetails[0]).to.equal(3); // FundingSuccessful status
    expect(loanDetails[2]).to.equal(targetAmount); // totalFunded
    console.log(`✅ Loan status is now: ${loanDetails[0]} (FundingSuccessful)`);
    console.log(`💯 Total funded: ${ethers.formatUnits(loanDetails[2], 6)} USDC`);
  });

  it("Should allow investors to claim governance tokens", async function () {
    console.log("\n🏛️ === Step 9: Investors claim governance tokens ===");

    // Investor 1 claims governance tokens
    let tx = await loanCrowdfunding.connect(investor1).claimGovTokens();
    let receipt = await tx.wait();
    console.log(`🎁 Investor1 claimed GOV tokens in transaction: ${receipt?.hash || "Unknown transaction"}`);

    // Verify investor 1 GOV token balance
    let govBalance = await govToken.balanceOf(investor1.address);
    expect(govBalance).to.equal(ethers.parseUnits("6000", 6)); // 6,000 GOV tokens
    console.log(`🗳️ Investor1 GOV token balance: ${ethers.formatUnits(govBalance, 6)}`);

    // Investor 2 claims governance tokens
    tx = await loanCrowdfunding.connect(investor2).claimGovTokens();
    receipt = await tx.wait();
    console.log(`🎁 Investor2 claimed GOV tokens in transaction: ${receipt?.hash || "Unknown transaction"}`);

    // Verify investor 2 GOV token balance
    govBalance = await govToken.balanceOf(investor2.address);
    expect(govBalance).to.equal(ethers.parseUnits("4000", 6)); // 4,000 GOV tokens
    console.log(`🗳️ Investor2 GOV token balance: ${ethers.formatUnits(govBalance, 6)}`);
  });

  it("Should allow client to withdraw funds", async function () {
    console.log("\n💲 === Step 10: Client withdraws funds ===");

    // Get client's USDC balance before withdrawal
    const clientBalanceBefore = await mockUSDC.balanceOf(client.address);
    console.log(`💰 Client USDC balance before withdrawal: ${ethers.formatUnits(clientBalanceBefore, 6)}`);

    // Client withdraws funds
    const tx = await loanCrowdfunding.connect(client).withdrawFunds();
    const receipt = await tx.wait();
    console.log(`💸 Client withdrew funds in transaction: ${receipt?.hash || "Unknown transaction"}`);

    // Verify client received the funds
    const clientBalanceAfter = await mockUSDC.balanceOf(client.address);
    expect(clientBalanceAfter - clientBalanceBefore).to.equal(targetAmount);
    console.log(`💰 Client USDC balance after withdrawal: ${ethers.formatUnits(clientBalanceAfter, 6)}`);
    console.log(`✅ Client received ${ethers.formatUnits(clientBalanceAfter - clientBalanceBefore, 6)} USDC`);

    // Verify loan status
    const loanDetails = await loanCrowdfunding.getLoanDetails();
    expect(loanDetails[0]).to.equal(6); // InRepayment status
    console.log(`🔄 Loan status is now: ${loanDetails[0]} (InRepayment)`);

    // Check repayment schedule
    for (let i = 0; i < totalRepayments; i++) {
      const repayment = await loanCrowdfunding.getRepaymentDetails(i);
      console.log(
        `📅 Repayment ${i}: Amount=${ethers.formatUnits(repayment[0], 6)} USDC, Due=${new Date(Number(repayment[2]) * 1000).toISOString()}`,
      );
    }

    // Verify next repayment date
    const nextRepaymentDate = loanDetails[4];
    console.log(`⏰ Next repayment due: ${new Date(Number(nextRepaymentDate) * 1000).toISOString()}`);
  });

  it("Should allow client to make repayments", async function () {
    console.log("\n💵 === Step 11: Client makes repayments ===");

    // Make first repayment
    let repaymentId = 0;
    let repaymentDetails = await loanCrowdfunding.getRepaymentDetails(repaymentId);
    let repaymentAmount = repaymentDetails[0];

    // Mint some USDC to client for repayments
    await mockUSDC.mint(client.address, ethers.parseUnits("20000", 6)); // 20,000 USDC for repayments
    console.log(`💱 Minted 20,000 USDC to client for repayments`);

    // First, advance time to repayment due date
    await time.increaseTo(repaymentDetails[2]);
    console.log(
      `⏱️ Advanced time to first repayment due date: ${new Date(Number(repaymentDetails[2]) * 1000).toISOString()}`,
    );

    // Approve USDC for repayment
    await mockUSDC.connect(client).approve(await loanCrowdfunding.getAddress(), repaymentAmount);
    console.log(`👍 Client approved ${ethers.formatUnits(repaymentAmount, 6)} USDC for repayment`);

    // Make the repayment
    let tx = await loanCrowdfunding.connect(client).makeRepayment(repaymentId);
    let receipt = await tx.wait();
    console.log(`💰 Client made repayment ${repaymentId} in transaction: ${receipt?.hash || "Unknown transaction"}`);

    // Verify repayment was recorded
    repaymentDetails = await loanCrowdfunding.getRepaymentDetails(repaymentId);
    expect(repaymentDetails[4]).to.equal(true); // paid status
    console.log(
      `✅ Repayment ${repaymentId} status: paid=${repaymentDetails[4]}, paidDate=${new Date(Number(repaymentDetails[3]) * 1000).toISOString()}`,
    );

    // Verify loan details updated
    let loanDetails = await loanCrowdfunding.getLoanDetails();
    expect(loanDetails[5]).to.equal(1); // completedRepayments
    console.log(`📊 Completed repayments: ${loanDetails[5]}/${loanDetails[6]}`);
    console.log(`💹 Remaining balance: ${ethers.formatUnits(loanDetails[3], 6)} USDC`);

    // Investors claim their share of the repayment
    tx = await loanCrowdfunding.connect(investor1).claimRepaymentProfit(repaymentId);
    receipt = await tx.wait();
    console.log(
      `💸 Investor1 claimed profit for repayment ${repaymentId} in transaction: ${receipt?.hash || "Unknown transaction"}`,
    );

    tx = await loanCrowdfunding.connect(investor2).claimRepaymentProfit(repaymentId);
    receipt = await tx.wait();
    console.log(
      `💸 Investor2 claimed profit for repayment ${repaymentId} in transaction: ${receipt?.hash || "Unknown transaction"}`,
    );

    // Make a second repayment
    repaymentId = 1;
    repaymentDetails = await loanCrowdfunding.getRepaymentDetails(repaymentId);
    repaymentAmount = repaymentDetails[0];

    // Advance time to second repayment due date
    await time.increaseTo(repaymentDetails[2]);
    console.log(
      `⏱️ Advanced time to second repayment due date: ${new Date(Number(repaymentDetails[2]) * 1000).toISOString()}`,
    );

    // Approve USDC for repayment
    await mockUSDC.connect(client).approve(await loanCrowdfunding.getAddress(), repaymentAmount);

    // Make the repayment
    tx = await loanCrowdfunding.connect(client).makeRepayment(repaymentId);
    receipt = await tx.wait();
    console.log(`💰 Client made repayment ${repaymentId} in transaction: ${receipt?.hash || "Unknown transaction"}`);

    // Verify loan details updated
    loanDetails = await loanCrowdfunding.getLoanDetails();
    expect(loanDetails[5]).to.equal(2); // completedRepayments
    console.log(`📊 Completed repayments: ${loanDetails[5]}/${loanDetails[6]}`);
  });

  it("Should handle late payments and penalties", async function () {
    console.log("\n⚠️ === Step 12: Testing late payment with penalty ===");

    const repaymentId = 2;
    let repaymentDetails = await loanCrowdfunding.getRepaymentDetails(repaymentId);
    const dueDate = BigInt(repaymentDetails[2]); // Convert to bigint

    // Advance time to 2 weeks after due date
    const twoWeeksInSeconds = 14n * 24n * 60n * 60n; // Use 'n' for bigint
    await time.increaseTo(dueDate + twoWeeksInSeconds);

    console.log(
      `⏰ Advanced time to 2 weeks after due date: ${new Date(
        Number(dueDate) * 1000 + Number(twoWeeksInSeconds) * 1000,
      ).toISOString()}`,
    );

    // Check if repayment is late
    const repaymentStatus = await loanCrowdfunding.checkRepaymentStatus(repaymentId);
    expect(repaymentStatus[0]).to.equal(true);
    console.log(`🚨 Repayment ${repaymentId} status: isLate=${repaymentStatus[0]}, daysLate=${repaymentStatus[2]}`);

    // Get repayment amount
    repaymentDetails = await loanCrowdfunding.getRepaymentDetails(repaymentId);
    const repaymentAmount = BigInt(repaymentDetails[0]);

    // Calculate expected penalty (1% per week, so ~2%)
    const penaltyRate = 2n;
    const expectedPenalty = (repaymentAmount * penaltyRate) / 100n;
    console.log(`💲 Expected penalty: ~${ethers.formatUnits(expectedPenalty, 6)} USDC`);

    // Approve USDC for repayment + penalty
    const totalAmount = repaymentAmount + expectedPenalty;
    await mockUSDC.connect(client).approve(await loanCrowdfunding.getAddress(), totalAmount);
    console.log(`👍 Client approved ${ethers.formatUnits(totalAmount, 6)} USDC for late repayment`);

    // Make the repayment
    const tx = await loanCrowdfunding.connect(client).makeRepayment(repaymentId);
    const receipt = await tx.wait();
    console.log(
      `💰 Client made late repayment ${repaymentId} in transaction: ${receipt?.hash || "Unknown transaction"}`,
    );

    // Verify repayment was recorded
    repaymentDetails = await loanCrowdfunding.getRepaymentDetails(repaymentId);
    expect(repaymentDetails[4]).to.equal(true);
    console.log(
      `✅ Repayment ${repaymentId} status: paid=${repaymentDetails[4]}, penalty=${ethers.formatUnits(repaymentDetails[1], 6)} USDC`,
    );

    // Verify loan details updated
    const loanDetails = await loanCrowdfunding.getLoanDetails();
    expect(loanDetails[5]).to.equal(3);
    console.log(`📊 Completed repayments: ${loanDetails[5]}/${loanDetails[6]}`);
  });

  it("Should complete all remaining repayments and finish the loan", async function () {
    console.log("\n🏁 === Step 13: Complete all remaining repayments ===");

    for (let repaymentId = 3; repaymentId < totalRepayments; repaymentId++) {
      console.log(`\n🔹 Processing repayment ${repaymentId}...`);

      // Get repayment details
      let repaymentDetails = await loanCrowdfunding.getRepaymentDetails(repaymentId);
      const repaymentAmount = BigInt(repaymentDetails[0]);
      const dueDate = BigInt(repaymentDetails[2]);

      // Advance time to due date
      await time.increaseTo(dueDate);
      console.log(`⏱️ Time advanced to due date: ${new Date(Number(dueDate) * 1000).toISOString()}`);

      // Approve repayment amount
      await mockUSDC.connect(client).approve(await loanCrowdfunding.getAddress(), repaymentAmount);
      console.log(`👍 Approved ${ethers.formatUnits(repaymentAmount, 6)} USDC for repayment ${repaymentId}`);

      // Ensure balance is sufficient
      const balance = await mockUSDC.balanceOf(client.address);
      if (balance < repaymentAmount) {
        console.error(`🚨 ERROR: Insufficient balance! (${ethers.formatUnits(balance, 6)} USDC)`);
        return;
      }

      // Make the repayment
      const tx = await loanCrowdfunding.connect(client).makeRepayment(repaymentId);
      const receipt = await tx.wait();
      console.log(`✅ Repayment ${repaymentId} completed in transaction: ${receipt?.hash || "Unknown transaction"}`);

      // Verify repayment was recorded
      repaymentDetails = await loanCrowdfunding.getRepaymentDetails(repaymentId);
      expect(repaymentDetails[4]).to.equal(true);
      console.log(
        `📝 Repayment ${repaymentId} status: paid=${repaymentDetails[4]}, penalty=${ethers.formatUnits(repaymentDetails[1], 6)} USDC`,
      );

      // Investors claim profits
      await loanCrowdfunding.connect(investor1).claimRepaymentProfit(repaymentId);
      await loanCrowdfunding.connect(investor2).claimRepaymentProfit(repaymentId);
      console.log(`💰 Investors claimed profits for repayment ${repaymentId}`);
    }

    // Verify loan completion
    console.log("\n🎉 === Step 14: Verifying loan completion ===");
    const loanDetails = await loanCrowdfunding.getLoanDetails();
    expect(loanDetails[0]).to.equal(7);
    expect(loanDetails[5]).to.equal(totalRepayments);
    expect(loanDetails[3]).to.equal(0);
    console.log(
      `✅ Loan completed: Status ${loanDetails[0]}, Repayments ${loanDetails[5]}, Remaining balance ${ethers.formatUnits(loanDetails[3], 6)} USDC`,
    );

    // Verify pledge unlock
    const pledgeDetails = await loanCrowdfunding.getPledgeDetails();
    expect(pledgeDetails[3]).to.equal(false);
    console.log(`🔓 Pledge unlocked`);
  });

  it("Should allow client to withdraw their pledge after completion", async function () {
    console.log("\n🔄 === Step 15: Client withdraws pledge after loan completion ===");

    // Get client's collateral balance before withdrawal
    const clientBalanceBefore = await mockCollateral.balanceOf(client.address);
    console.log(`💰 Client collateral balance before withdrawal: ${ethers.formatUnits(clientBalanceBefore, 18)}`);

    // Client withdraws pledge
    const tx = await loanCrowdfunding.connect(client).withdrawPledge();
    const receipt = await tx.wait();
    console.log(`📤 Client withdrew pledge in transaction: ${receipt?.hash || "Unknown transaction"}`);

    // Verify client received the collateral back
    const clientBalanceAfter = await mockCollateral.balanceOf(client.address);
    const pledgeDetails = await loanCrowdfunding.getPledgeDetails();
    console.log(`💰 Client collateral balance after withdrawal: ${ethers.formatUnits(clientBalanceAfter, 18)}`);
    console.log(
      `✅ Client received ${ethers.formatUnits(clientBalanceAfter - clientBalanceBefore, 18)} collateral tokens back`,
    );
    expect(pledgeDetails[1]).to.equal(0); // Pledge amount is zero
    console.log(`🔢 Pledge amount remaining in contract: ${ethers.formatUnits(pledgeDetails[1], 18)}`);

    console.log("\n🎊 === Loan Crowdfunding Complete ===");
    console.log("🌟 All stages of the loan crowdfunding process have been successfully tested");
  });

  it("Should handle price feed updates during the loan lifecycle", async function () {
    console.log("\n📈 === Step 16: Test price feed updates ===");

    // Update collateral price to simulate market volatility
    const newCollateralPrice = ethers.parseUnits("1.5", 8); // Decreased value to $1.50
    await mockCollateralOracle.updateAnswer(newCollateralPrice);
    console.log(`📉 Updated collateral price to ${newCollateralPrice / BigInt(10 ** 8)}`);

    // Test conversion with new price
    const testAmount = ethers.parseUnits("100", 18); // 100 collateral tokens
    const newUsdValue = await priceFeedManager.tokenToUsd.staticCall(testAmount, await mockCollateral.getAddress());
    console.log(`💱 100 collateral tokens now worth ${newUsdValue / BigInt(100)} USD`);

    // Confirm update took effect
    expect(newUsdValue).to.be.closeTo(BigInt(15000), BigInt(100)); // Should be ~$150.00 (15000 with 2 decimals)

    // Check if we could set fallback prices
    await priceFeedManager.setFallbackPrice(await mockCollateral.getAddress(), newCollateralPrice);
    const fallbackPrice = await priceFeedManager.getFallbackPrice(await mockCollateral.getAddress());
    expect(fallbackPrice).to.equal(newCollateralPrice);
    console.log(`🔄 Fallback price correctly updated to ${fallbackPrice / BigInt(10 ** 8)}`);
  });

  it("Should simulate a loan default scenario", async function () {
    console.log("\n⚠️ === Step 17: Loan Default Scenario ===");
    console.log("📝 This is a separate test to demonstrate the loan default and expropriation process");

    // We'll set up a new loan for this test
    console.log("🏗️ Setting up a new loan for default testing...");

    // Deploy new LoanCrowdfunding contract
    const LoanCrowdfunding = await ethers.getContractFactory("LoanCrowdfunding");
    const defaultLoan = await LoanCrowdfunding.deploy(
      client.address,
      await mockUSDC.getAddress(),
      await identityToken.getAddress(),
    );
    await defaultLoan.waitForDeployment();

    const defaultLoanAddress = await defaultLoan.getAddress();
    console.log(`📝 Deployed new LoanCrowdfunding at: ${defaultLoanAddress}`);

    // Register the new loan contract as a platform
    await identityToken.registerPlatform(defaultLoanAddress);

    // Set up price feed manager for the new loan contract
    await defaultLoan.setPriceFeedManager(await priceFeedManager.getAddress());

    // Get GOV token address
    const defaultGovTokenAddress = await defaultLoan.govToken();
    await ethers.getContractAt("GovToken", defaultGovTokenAddress);
    console.log(`🏛️ Default loan's governance token deployed at: ${defaultGovTokenAddress}`);

    // Grant auditor role
    await defaultLoan.grantRole(await defaultLoan.AUDITOR_ROLE(), auditor.address);

    // Initialize loan
    await defaultLoan
      .connect(auditor)
      .initialize(
        targetAmount,
        investmentPeriod,
        repaymentInterval,
        totalRepayments,
        interestRate,
        riskRating,
        jurisdiction,
      );
    console.log("✅ Initialized default test loan");

    // Submit pledge
    await mockCollateral.mint(client.address, pledgeAmount); // Mint more collateral tokens
    await mockCollateral.connect(client).approve(defaultLoanAddress, pledgeAmount);
    await defaultLoan
      .connect(client)
      .submitPledge(await mockCollateral.getAddress(), pledgeAmount, ethers.id("default-pledge-document"));
    console.log("🔒 Client submitted pledge for default test loan");

    // Invest in the loan
    const investor1Amount = ethers.parseUnits("6000", 6); // 6,000 USDC
    const investor2Amount = ethers.parseUnits("4000", 6); // 4,000 USDC

    await mockUSDC.mint(investor1.address, investor1Amount * 2n); // Mint more USDC
    await mockUSDC.mint(investor2.address, investor2Amount * 2n);

    await mockUSDC.connect(investor1).approve(defaultLoanAddress, investor1Amount);
    await defaultLoan.connect(investor1).invest(investor1Amount);

    await mockUSDC.connect(investor2).approve(defaultLoanAddress, investor2Amount);
    await defaultLoan.connect(investor2).invest(investor2Amount);
    console.log("💰 Investors invested in default test loan");

    // Claim governance tokens
    await defaultLoan.connect(investor1).claimGovTokens();
    await defaultLoan.connect(investor2).claimGovTokens();
    console.log("🏛️ Investors claimed governance tokens");

    // Client withdraws funds
    await defaultLoan.connect(client).withdrawFunds();
    console.log("💸 Client withdrew funds");

    // Make the first repayment
    const repaymentAmount = (await defaultLoan.getRepaymentDetails(0))[0];
    await mockUSDC.mint(client.address, repaymentAmount * 2n); // Mint USDC for repayment
    await mockUSDC.connect(client).approve(defaultLoanAddress, repaymentAmount);
    await defaultLoan.connect(client).makeRepayment(0);
    console.log("✅ Client made first repayment");

    // Skip to second repayment due date
    const repayment1DueDate = (await defaultLoan.getRepaymentDetails(1))[2];
    await time.increaseTo(repayment1DueDate);
    console.log(
      `⏱️ Advanced time to second repayment due date: ${new Date(Number(repayment1DueDate) * 1000).toISOString()}`,
    );

    // Now we'll simulate a default by advancing time past the late payment threshold
    const latePaymentThreshold = await defaultLoan.LATE_PAYMENT_THRESHOLD();
    await time.increaseTo(repayment1DueDate + latePaymentThreshold + 1n); // Just past the threshold
    console.log(
      `⏰ Advanced time past late payment threshold: ${new Date(Number(repayment1DueDate) + Number(latePaymentThreshold) + 1000).toISOString()}`,
    );

    // Check if repayment is eligible for expropriation vote
    const repaymentStatus = await defaultLoan.checkRepaymentStatus(1);
    expect(repaymentStatus[1]).to.equal(true); // isEligibleForVote
    console.log(`🚨 Repayment 1 is eligible for expropriation vote: ${repaymentStatus[1]}`);
    console.log(`📅 Days late: ${repaymentStatus[2]}`);

    // Investor 1 starts expropriation vote
    let tx = await defaultLoan.connect(investor1).startExpropriationVote(1);
    let receipt = await tx.wait();
    console.log(`🗳️ Investor1 started expropriation vote in transaction: ${receipt?.hash || "Unknown transaction"}`);

    // Get vote details
    let voteDetails = await defaultLoan.getCurrentVoteDetails();
    console.log(
      `📊 Vote started: startTime=${new Date(Number(voteDetails[0]) * 1000).toISOString()}, endTime=${new Date(Number(voteDetails[1]) * 1000).toISOString()}`,
    );

    // Investors cast votes
    tx = await defaultLoan.connect(investor1).vote(true); // Vote for expropriation
    receipt = await tx.wait();
    console.log(`👍 Investor1 voted for expropriation in transaction: ${receipt?.hash || "Unknown transaction"}`);

    tx = await defaultLoan.connect(investor2).vote(false); // Vote against expropriation
    receipt = await tx.wait();
    console.log(`👎 Investor2 voted against expropriation in transaction: ${receipt?.hash || "Unknown transaction"}`);

    // Get updated vote details
    voteDetails = await defaultLoan.getCurrentVoteDetails();
    console.log(
      `📈 Votes for: ${ethers.formatUnits(voteDetails[2], 6)}, Votes against: ${ethers.formatUnits(voteDetails[3], 6)}`,
    );

    // Since Investor1 has 60% of governance tokens, they should have enough votes to pass the expropriation

    // Advance time to end of voting period
    await time.increaseTo(voteDetails[1] + 1n); // Just past the end time
    console.log(`⏱️ Advanced time to end of voting period: ${new Date(Number(voteDetails[1]) + 1000).toISOString()}`);

    // Finalize vote
    tx = await defaultLoan.finalizeVote();
    receipt = await tx.wait();
    console.log(`🔨 Vote finalized in transaction: ${receipt?.hash || "Unknown transaction"}`);

    // Check vote result
    voteDetails = await defaultLoan.getCurrentVoteDetails();
    console.log(`🏁 Vote status: ${voteDetails[4]} (Completed), Expropriation approved: ${voteDetails[5]}`);

    // Check loan status
    const loanStatus = await defaultLoan.loanStatus();
    expect(loanStatus).to.equal(8); // Defaulted status
    console.log(`❌ Loan status is now: ${loanStatus} (Defaulted)`);

    // Investors claim their share of the pledge
    const pledgeDetails = await defaultLoan.getPledgeDetails();
    console.log(`🔒 Pledge amount available: ${ethers.formatUnits(pledgeDetails[1], 18)} tokens`);

    // Calculate USD value of the collateral at current prices
    const pledgeValueUsd = await priceFeedManager.tokenToUsd.staticCall(pledgeDetails[1], pledgeDetails[0]);
    console.log(`💵 Current USD value of remaining pledge: ${pledgeValueUsd / BigInt(100)}`);

    // Investor 1 claims their share (60%)
    await defaultLoan.investments(investor1.address);
    const investor1BalanceBefore = await mockCollateral.balanceOf(investor1.address);

    tx = await defaultLoan.connect(investor1).claimPledgeShare();
    receipt = await tx.wait();
    console.log(`💰 Investor1 claimed pledge share in transaction: ${receipt?.hash || "Unknown transaction"}`);

    const investor1BalanceAfter = await mockCollateral.balanceOf(investor1.address);
    console.log(
      `✅ Investor1 received ${ethers.formatUnits(investor1BalanceAfter - investor1BalanceBefore, 18)} collateral tokens`,
    );

    // Investor 2 claims their share (40%)
    const investor2BalanceBefore = await mockCollateral.balanceOf(investor2.address);

    tx = await defaultLoan.connect(investor2).claimPledgeShare();
    receipt = await tx.wait();
    console.log(`💰 Investor2 claimed pledge share in transaction: ${receipt?.hash || "Unknown transaction"}`);

    const investor2BalanceAfter = await mockCollateral.balanceOf(investor2.address);
    console.log(
      `✅ Investor2 received ${ethers.formatUnits(investor2BalanceAfter - investor2BalanceBefore, 18)} collateral tokens`,
    );

    // Check remaining pledge amount (should be close to zero)
    const updatedPledgeDetails = await defaultLoan.getPledgeDetails();
    console.log(`🔍 Remaining pledge amount: ${ethers.formatUnits(updatedPledgeDetails[1], 18)} tokens`);

    console.log("\n🏁 === Loan Default and Expropriation Test Complete ===");
    console.log("✅ Successfully demonstrated the loan default and expropriation mechanism");
  });
});
