import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { Contract } from "ethers";

/**
 * Deploys the LoanCrowdfunding contract with Identity Verification
 *
 * @param hre HardhatRuntimeEnvironment object.
 */
const deployLoanCrowdfunding: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  console.log(`\n=== Deploying LoanCrowdfunding with deployer: ${deployer} ===`);

  // Client address - from .env or named accounts
  const client = process.env.CLIENT_ADDRESS || (await hre.getNamedAccounts()).client || deployer;

  // Get the stablecoin address
  let stablecoinAddress = process.env.STABLECOIN_ADDRESS;
  /* eslint-disable*/
  if (!stablecoinAddress) {
    // Check if MockUSDC is deployed
    try {
      const mockUSDCDeployment = await hre.deployments.get("MockUSDC");
      stablecoinAddress = mockUSDCDeployment.address;
      console.log(`Using MockUSDC as stablecoin at: ${stablecoinAddress}`);
    } catch (error) {
      console.error("No stablecoin address provided and MockUSDC not found.");
      console.error("Please run: yarn deploy --tags MockUSDC");
      console.error("Or provide a STABLECOIN_ADDRESS in your .env file");
      throw new Error("Stablecoin address not found");
    }
  }

  // Get the IdentitySoulboundToken address
  let identityTokenAddress = process.env.IDENTITY_TOKEN_ADDRESS;

  if (!identityTokenAddress) {
    // Check if IdentitySoulboundToken is deployed
    try {
      const identityTokenDeployment = await hre.deployments.get("IdentitySoulboundToken");
      identityTokenAddress = identityTokenDeployment.address;
      console.log(`Using IdentitySoulboundToken at: ${identityTokenAddress}`);
    } catch (error) {
      console.error("No identity token address provided and IdentitySoulboundToken not found.");
      console.error("Please run: yarn deploy --tags IdentityToken");
      console.error("Or provide a IDENTITY_TOKEN_ADDRESS in your .env file");
      throw new Error("Identity token address not found");
    }
  }
  /*eslint-enable*/

  // Get the identity token contract to register our platform
  const identityToken = await hre.ethers.getContractAt("IdentitySoulboundToken", identityTokenAddress);

  // Verify that client has a valid verification token
  try {
    console.log(`Checking if client ${client} has a valid verification...`);
    const verificationResult = await identityToken.checkVerification(
      client,
      deployer, // We're checking from the deployer context
      0, // Client type (0)
    );

    if (!verificationResult[0]) {
      console.warn(`WARNING: Client ${client} does not have a valid verification token!`);
      console.warn("Deployment will proceed, but contract initialization may fail.");

      // If on testnet, try to verify the client automatically
      if (hre.network.name === "localhost" || hre.network.name === "hardhat") {
        console.log("Attempting to verify client for testing purposes...");

        // Generate document hash for testing
        const clientDocHash = hre.ethers.id(`CLIENT_TEST_${client}`);

        // Set expiration one year from now (in seconds)
        const oneYear = Math.floor(Date.now() / 1000) + 365 * 24 * 60 * 60;

        // Verify the client
        try {
          const verifyTx = await identityToken.verifyClient(
            client,
            "TEST-JURISDICTION", // Test jurisdiction
            clientDocHash,
            oneYear,
            "", // No token URI for testing
          );
          await verifyTx.wait();
          console.log(`Successfully verified client ${client} for testing`);
        } catch (error) {
          console.error("Failed to automatically verify client:", error);
        }
      } else {
        console.warn("Please verify the client before initializing the contract.");
      }
    } else {
      console.log(`Client ${client} verification confirmed!`);
    }
  } catch (error) {
    console.error("Error checking client verification:", error);
  }

  // Deploy the LoanCrowdfunding contract
  console.log(`\nDeploying LoanCrowdfunding with parameters:
  - Client: ${client}
  - Stablecoin: ${stablecoinAddress}
  - Identity Token: ${identityTokenAddress}`);

  const loanCrowdfundingDeployment = await deploy("LoanCrowdfunding", {
    from: deployer,
    args: [client, stablecoinAddress, identityTokenAddress],
    log: true,
    autoMine: true,
  });

  console.log(`LoanCrowdfunding deployed at address: ${loanCrowdfundingDeployment.address}`);

  // Get the deployed contract
  const loanCrowdfunding = await hre.ethers.getContract<Contract>("LoanCrowdfunding", deployer);

  // Get the address of the GovToken created by the LoanCrowdfunding contract
  const govTokenAddress = await loanCrowdfunding.govToken();
  console.log(`GovToken created at address: ${govTokenAddress}`);

  // Register the LoanCrowdfunding contract with the IdentitySoulboundToken
  console.log(`\nRegistering LoanCrowdfunding contract with the IdentitySoulboundToken...`);
  try {
    const registerTx = await identityToken.registerPlatform(loanCrowdfundingDeployment.address);
    await registerTx.wait();
    console.log(`Successfully registered LoanCrowdfunding as a platform`);
  } catch (error) {
    console.error("Failed to register platform:", error);
  }

  // Verify that the deployer has a valid auditor verification token
  // If not, create one for testing purposes on test networks
  try {
    const verificationResult = await identityToken.checkVerification(
      deployer,
      loanCrowdfundingDeployment.address,
      2, // Auditor type (2)
    );

    if (!verificationResult[0] && (hre.network.name === "localhost" || hre.network.name === "hardhat")) {
      console.log(`Verifying deployer ${deployer} as an auditor for testing...`);

      // Generate document hash for testing
      const auditorDocHash = hre.ethers.id(`AUDITOR_TEST_${deployer}`);

      // Set expiration one year from now (in seconds)
      const oneYear = Math.floor(Date.now() / 1000) + 365 * 24 * 60 * 60;

      // Verify the deployer as an auditor
      const verifyTx = await identityToken.verifyAuditor(
        deployer,
        "TEST-JURISDICTION",
        auditorDocHash,
        oneYear,
        "", // No token URI for testing
      );
      await verifyTx.wait();
      console.log(`Successfully verified deployer as an auditor for testing`);
    }
  } catch (error) {
    console.error("Error checking/setting auditor verification:", error);
  }

  // If on test network, initialize the contract with test values
  if (hre.network.name === "localhost" || hre.network.name === "hardhat") {
    try {
      console.log(`\nInitializing LoanCrowdfunding with test values...`);

      // Example initialization parameters for testing
      const targetAmount = hre.ethers.parseUnits("100000", 6); // 100,000 USDC with 6 decimals
      const investmentPeriod = 30 * 24 * 60 * 60; // 30 days in seconds
      const repaymentInterval = 30 * 24 * 60 * 60; // Monthly repayments (30 days)
      const totalRepayments = 12; // 12 monthly repayments
      const interestRate = 1000; // 10% annual interest rate (basis points)
      const riskRating = 50; // Medium risk (1-100)
      const jurisdiction = "TEST-JURISDICTION";

      // Initialize the contract
      const initTx = await loanCrowdfunding.initialize(
        targetAmount,
        investmentPeriod,
        repaymentInterval,
        totalRepayments,
        interestRate,
        riskRating,
        jurisdiction,
      );
      await initTx.wait();
      console.log(`LoanCrowdfunding initialized successfully with test values`);
    } catch (error) {
      console.error("Failed to initialize contract with test values:", error);
      console.error("You may need to manually initialize the contract");
    }
  }

  console.log("\nLoanCrowdfunding deployment and setup completed successfully");
};

export default deployLoanCrowdfunding;

// Tags
deployLoanCrowdfunding.tags = ["LoanCrowdfunding"];
deployLoanCrowdfunding.dependencies = ["IdentityToken", "MockUSDC"];
