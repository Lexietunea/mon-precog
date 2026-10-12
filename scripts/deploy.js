async function main() {
  const [deployer] = await ethers.getSigners();
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log('Deploying Precog from:', deployer.address);
  console.log('Deployer balance:', ethers.formatEther(balance), 'MON');

  const Precog = await ethers.getContractFactory('Precog');
  const precog = await Precog.deploy();
  await precog.waitForDeployment();

  console.log('Precog deployed to:', await precog.getAddress());
  console.log('Monad Testnet explorer:', `https://testnet.monadvision.com/address/${await precog.getAddress()}`);
  console.log('Save this address and configure the website before enabling on-chain calls.');
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});