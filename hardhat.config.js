const { version } = require("chai");

require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-etherscan");
require('@openzeppelin/hardhat-upgrades');
require("hardhat-watcher");
require('hardhat-contract-sizer');
require("dotenv").config();

const PRIVATE_KEY = process.env.PRIVATE_KEY;
const APIKEY = process.env.APIKEY;

module.exports = {
  defaultNetwork: "bsc_testnet",
  networks: {
    bsc_testnet: {
      throwOnTransactionFailures: true,
      throwOnCallFailures: true,
      allowUnlimitedContractSize: true,
      blockGasLimit: 0x1fffffffffffff,
      gas: 120000000000000,
      timeout: 1800000,
      url: "https://data-seed-prebsc-2-s1.binance.org:8545",
      accounts: [PRIVATE_KEY]
    }
  },
  watcher: {
    compilation: {
      tasks: ["compile"],
      files: ["./contracts"],
      verbose: true,
    },
    ci: {
      tasks: ["clean", { command: "compile", params: { quiet: true } }, {
        command: "test",
        params: { noCompile: true, testFiles: ["testfile.ts"] }
      }],
    }
  },
  etherscan: {
    apiKey: APIKEY
  },
  solidity: {
    version: "0.8.9",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1000,
      },
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  },
  mocha: {
    timeout: 2000000
  },
  contractSizer: {
    // alphaSort: true,
    // disambiguatePaths: false,
    // runOnCompile: true,
    // strict: true,
  }
}