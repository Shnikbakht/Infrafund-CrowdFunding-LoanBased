import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { Contract } from "ethers";

/**
 * Deploys the IdentitySoulboundToken contract for participant verification
 *
 * @param hre HardhatRuntimeEnvironment object.
 */
const deployIdentityToken: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  console.log(`\n=== Deploying IdentitySoulboundToken with deployer: ${deployer} ===`);

  // Deploy the IdentitySoulboundToken contract
  const identityTokenDeployment = await deploy("IdentitySoulboundToken", {
    from: deployer,
    args: [], // No constructor arguments
    log: true,
    autoMine: true,
  });

  console.log(`IdentitySoulboundToken deployed at address: ${identityTokenDeployment.address}`);

  // Get the deployed contract
  const identityToken = await hre.ethers.getContract<Contract>("IdentitySoulboundToken", deployer);

  // Set up additional verifiers if needed
  const additionalVerifier = process.env.VERIFIER_ADDRESS;
  if (additionalVerifier && additionalVerifier !== deployer) {
    console.log(`Granting VERIFIER_ROLE to ${additionalVerifier}...`);

    // Get VERIFIER_ROLE from the contract
    const verifierRole = await identityToken.VERIFIER_ROLE();

    // Grant the role
    const tx = await identityToken.grantRole(verifierRole, additionalVerifier);
    await tx.wait();
    console.log(`VERIFIER_ROLE granted to ${additionalVerifier}`);
  }

  // Set up compliance officers if specified
  const complianceOfficer = process.env.COMPLIANCE_ADDRESS;
  if (complianceOfficer && complianceOfficer !== deployer) {
    console.log(`Granting COMPLIANCE_ROLE to ${complianceOfficer}...`);

    // Get COMPLIANCE_ROLE from the contract
    const complianceRole = await identityToken.COMPLIANCE_ROLE();

    // Grant the role
    const tx = await identityToken.grantRole(complianceRole, complianceOfficer);
    await tx.wait();
    console.log(`COMPLIANCE_ROLE granted to ${complianceOfficer}`);
  }

  // For testing: verify the client address if defined in .env
  const clientAddress = process.env.CLIENT_ADDRESS;
  if (clientAddress && hre.network.name !== "mainnet") {
    try {
      console.log(`\nVerifying client at ${clientAddress} for testing...`);

      // Generate document hash for testing
      const clientDocHash = hre.ethers.id(`CLIENT_TEST_${clientAddress}`);

      // Set expiration one year from now (in seconds)
      const oneYear = Math.floor(Date.now() / 1000) + 365 * 24 * 60 * 60;

      // Verify the client
      const verifyTx = await identityToken.verifyClient(
        clientAddress,
        "TEST-JURISDICTION", // Test jurisdiction
        clientDocHash,
        oneYear,
        "", // No token URI for testing
      );
      await verifyTx.wait();

      console.log(`Test client verified successfully, expiring in 1 year`);
    } catch (error) {
      console.error("Error verifying test client:", error);
    }
  }

  // For testing: verify sample investors if we're on a test network
  if (hre.network.name === "localhost" || hre.network.name === "hardhat") {
    try {
      // Find all named accounts to use as test investors
      const namedAccounts = await hre.getNamedAccounts();
      const possibleInvestors = [namedAccounts.investor1, namedAccounts.investor2, namedAccounts.investor3];

      for (let i = 0; i < possibleInvestors.length; i++) {
        const investor = possibleInvestors[i];
        if (investor && investor !== deployer && investor !== clientAddress) {
          console.log(`\nVerifying test investor at ${investor}...`);

          // Generate document hash for testing
          const investorDocHash = hre.ethers.id(`INVESTOR_TEST_${investor}`);

          // Set expiration one year from now (in seconds)
          const oneYear = Math.floor(Date.now() / 1000) + 365 * 24 * 60 * 60;

          // Set investment limit based on index (for testing different tiers)
          const investmentLimits = [50000, 250000, 1000000]; // $50K, $250K, $1M
          const accreditationStatus = [1, 2, 3]; // NonAccredited, AccreditedIndividual, InstitutionalInvestor
          const riskTolerances = [1, 2, 3]; // Conservative, Moderate, Aggressive

          // Verify the investor
          const verifyTx = await identityToken.verifyInvestor(
            investor,
            "TEST-JURISDICTION",
            investorDocHash,
            oneYear,
            investmentLimits[i % 3], // Investment limit
            riskTolerances[i % 3], // Risk tolerance
            accreditationStatus[i % 3], // Accreditation status
            "", // No token URI for testing
          );
          await verifyTx.wait();

          console.log(`Test investor verified successfully with $${investmentLimits[i % 3]} investment limit`);
        }
      }
    } catch (error) {
      console.error("Error verifying test investors:", error);
    }
  }

  console.log("\nIdentity token deployment and setup completed successfully");
};

export default deployIdentityToken;

// Tags
deployIdentityToken.tags = ["IdentityToken"];
