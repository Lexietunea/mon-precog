require('@nomicfoundation/hardhat-ethers');
require('dotenv').config();
const { subtask } = require('hardhat/config');
const { TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD } = require('hardhat/builtin-tasks/task-names');

subtask(TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD).setAction(async ({ solcVersion }, _, runSuper) => {
  if (solcVersion === '0.8.28') {
    return {
      compilerPath: require.resolve('solc/soljson.js'),
      isSolcJs: true,
      version: solcVersion,
      longVersion: require('solc').version()
    };
  }
  return runSuper();
});

const accounts = process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : [];

module.exports = {
  solidity: {
    version: '0.8.28',
    settings: { optimizer: { enabled: true, runs: 300 } }
  },
  networks: {
    monadTestnet: {
      url: process.env.MONAD_TESTNET_RPC_URL || 'https://testnet-rpc.monad.xyz',
      chainId: 10143,
      accounts
    }
  },
  paths: { tests: './test' }
};