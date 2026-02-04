import hre from "hardhat";

async function main() {
  // Base Sepolia USDC address
  const USDC_ADDRESS = "0x036cbd53842c5426634e7929541ec2318f3dcf7e";

  console.log("Deploying AgentIdentityRegistry...");
  console.log("Network:", hre.network.name);
  console.log("USDC Address:", USDC_ADDRESS);

  const AgentIdentityRegistry = await hre.ethers.getContractFactory("AgentIdentityRegistry");
  const registry = await AgentIdentityRegistry.deploy(USDC_ADDRESS);

  await registry.waitForDeployment();

  const address = await registry.getAddress();
  console.log("AgentIdentityRegistry deployed to:", address);

  // Verify on Basescan
  if (hre.network.name === "baseSepolia" || hre.network.name === "base") {
    console.log("Waiting for block confirmations...");
    await registry.deploymentTransaction().wait(5);

    console.log("Verifying contract on Basescan...");
    try {
      await hre.run("verify:verify", {
        address: address,
        constructorArguments: [USDC_ADDRESS],
      });
      console.log("Contract verified!");
    } catch (error) {
      console.log("Verification failed:", error.message);
    }
  }

  return address;
}

main()
  .then((address) => {
    console.log("\n✅ Deployment complete!");
    console.log("Contract address:", address);
    process.exit(0);
  })
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
