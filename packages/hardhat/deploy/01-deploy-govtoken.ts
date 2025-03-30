import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { Contract } from "ethers";

/**
 * Deploys the GovToken contract using the deployer account
 *
 * @param hre HardhatRuntimeEnvironment object.
 */
const deployGovToken: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  /*
    On localhost, the deployer account is the one that comes with Hardhat, which is already funded.

    When deploying to live networks (e.g `yarn deploy --network sepolia`), the deployer account
    should have sufficient balance to pay for the gas fees for contract creation.

    You can generate a random account with `yarn generate` or `yarn account:import` to import your
    existing PK which will fill DEPLOYER_PRIVATE_KEY_ENCRYPTED in the .env file (then used on hardhat.config.ts)
    You can run the `yarn account` command to check your balance in every network.
  */
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  // Deploy GovToken
  const govTokenDeployment = await deploy("GovToken", {
    from: deployer,
    args: [], // GovToken constructor takes no arguments
    log: true,
    autoMine: true,
  });

  console.log(`GovToken deployed at address: ${govTokenDeployment.address}`);

  // Get the deployed contract to interact with it after deploying
  await hre.ethers.getContract<Contract>("GovToken", deployer);
  console.log("GovToken deployed successfully");

  // No need to return anything - hardhat-deploy automatically keeps track of deployments
  // The deployed address can be accessed in subsequent scripts using hre.deployments.get("GovToken")
};

export default deployGovToken;

// Tags are useful if you have multiple deploy files and only want to run one of them.
// e.g. yarn deploy --tags GovToken
deployGovToken.tags = ["GovToken"];
