const { version } = require("chai");

require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-etherscan");
require("@openzeppelin/hardhat-upgrades");
require("hardhat-watcher");
require("hardhat-contract-sizer");
require("dotenv").config();

const PRIVATE_KEY = process.env.PRIVATE_KEY;
const APIKEY = process.env.APIKEY;

module.exports = {
  defaultNetwork: "goerli_testnet",
  networks: {
    hardhat: {},
    bsc_testnet: {
      url: "https://data-seed-prebsc-1-s1.binance.org:8545",
      accounts: [PRIVATE_KEY],
    },
    goerli_testnet: {
      url: "https://goerli.infura.io/v3/88904a7034a74f0fa8c2de15a4928e34",
      accounts: [PRIVATE_KEY],
    },
  },
  watcher: {
    compilation: {
      tasks: ["compile"],
      files: ["./contracts"],
      verbose: true,
    },
    ci: {
      tasks: [
        "clean",
        { command: "compile", params: { quiet: true } },
        {
          command: "test",
          params: { noCompile: true, testFiles: ["testfile.ts"] },
        },
      ],
    },
  },
  etherscan: {
    apiKey: APIKEY, // bsc
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
    artifacts: "./artifacts",
  },
  mocha: {
    timeout: 2000000,
  },
  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: true,
    strict: true,
  },
};
