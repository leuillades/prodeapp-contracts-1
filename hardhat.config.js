require("@nomiclabs/hardhat-waffle");
require("@reality.eth/contracts")
require("@nomiclabs/hardhat-etherscan");
const { mnemonic, etherscanApiKey } = require('./secrets.json');

const CHAIN_IDS = {
  hardhat: 31337, // chain ID for hardhat testing
};

// This is a sample Hardhat task. To learn how to create your own go to
// https://hardhat.org/guides/create-task.html
task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: "0.8.13",
  settings: {
    optimizer: {
      enabled: true,
      runs: 1000,
    },
  },
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true,
    },
    gnosis: {
      url: 'https://rpc.gnosischain.com/',
      accounts: { mnemonic },
      gasPrice: 10000000000
    }
  },
  etherscan: {
    apiKey: etherscanApiKey
    }
  
};

