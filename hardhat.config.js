require('@nomiclabs/hardhat-waffle');
require('@nomiclabs/hardhat-etherscan');
require('hardhat-contract-sizer');
require("hardhat-gas-reporter");

module.exports = {
  'gasReporter': {
    'currency': 'CHF',
    'gasPrice': 21
  },
  'etherscan': {
    'apiKey': '6TKH29HCYTU6WHU2FF11QPATCY4UQ6HQ8G', 
  },
  'mocha': {
    'timeout': 20000,
  },
  'networks': {
    'hardhat': {},
    'goerli': {
      'accounts': ['a4f96c04ed56df73a0f1b36bcdac8b479f75d08459817435e3b2b95c8d49724c'],
      'url': 'https://goerli.optimism.io',
    },
  },
  'paths': {
    'sources': './contracts',
    'artifacts': './artifacts',
    'cache': './cache',
    'tests': './test',
  },
  'solidity': {
    'compilers': [
      {
        'version': '0.8.17',
      },
      {
        'version': '0.8.9',
      },
      {
        'version': '0.8.7',
      },
      {
        'version': '0.8.0',
      },
    ],
    'settings': {
      'optimizer': {
        'enabled': true,
        'runs': 200,
      },
    },
  },
  'watcher': {
    'ci': {
      'tasks': [
        'clean',
        {
          'command': 'compile',
          'params': { 'quiet': true }
        },
        {
          'command': 'test',
          'params': {
            'noCompile': true,
            'testFiles': ['testfile.ts']
          },
        },
      ],
    },
    'compilation': {
      'tasks': ['compile'],
      'files': ['./contracts'],
      'verbose': true,
    },
  },
};
