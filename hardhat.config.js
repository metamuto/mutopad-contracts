const { version } = require("chai");

require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-etherscan");
require('@openzeppelin/hardhat-upgrades');
require("hardhat-watcher");
require('hardhat-contract-sizer');
require("dotenv").config();

const PRIVATE_KEY = process.env.PRIVATE_KEY_381;
const APIKEY = process.env.API_KEY_BSC;

module.exports = {
  defaultNetwork: "bsc_testnet",
  etherscan: {
    apiKey: APIKEY
  },
  networks: {
    bsc_testnet: {
      timeout: 1800000,
      url: "https://data-seed-prebsc-1-s2.binance.org:8545",
      accounts: [PRIVATE_KEY]}
    // },
    // goerli: {
    //   timeout: 1800000,
    //   url: "https://goerli.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161",
    //   accounts: PRIVATE_KEY
    // }
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
  solidity: {
    version: "0.8.9",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
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
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: true,
    strict: true,
  }
}