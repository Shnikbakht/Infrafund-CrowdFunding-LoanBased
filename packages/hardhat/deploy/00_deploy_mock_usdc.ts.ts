import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";

/**
 * Deploys a mock USDC token for testing
 *
 * @param hre HardhatRuntimeEnvironment object.
 */
const deployMockUSDC: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  // Only deploy in development environment
  if (hre.network.name === "localhost" || hre.network.name === "hardhat") {
    console.log("Deploying MockUSDC for local testing...");

    const mockUSDC = await deploy("MockUSDC", {
      from: deployer,
      args: ["Mock USDC", "mUSDC", 6], // name, symbol, decimals (USDC has 6 decimals)
      log: true,
      autoMine: true,
    });

    console.log(`MockUSDC deployed at address: ${mockUSDC.address}`);

    // Get the contract to interact with using getContractAt which lets us specify the type
    const mockUSDCContract = await hre.ethers.getContractAt("MockUSDC", mockUSDC.address);

    // Mint some tokens to the deployer for testing
    const mintAmount = hre.ethers.parseUnits("1000000", 6); // 1 million USDC

    // TypeScript workaround - we know this function exists
    const mintTx = await (mockUSDCContract as any).mint(deployer, mintAmount);
    await mintTx.wait();

    console.log(`Minted ${hre.ethers.formatUnits(mintAmount, 6)} MockUSDC to ${deployer}`);
  } else {
    console.log("Skipping MockUSDC deployment on non-development network");
  }
};

export default deployMockUSDC;

deployMockUSDC.tags = ["MockUSDC"];
