const { ethers } = require('hardhat');
/** This is a function used to deploy contract */
const hre = require('hardhat');

async function main() {
  const MutoPool = await hre.ethers.getContractFactory('MutoPool');
  const _MutoPool = await MutoPool.deploy();
  console.log(
    'MutoPool deployed to:',
    _MutoPool.address,
  );
}

main().
  then(() => process.exit(0)).
  catch((error) => {
    console.error(error);
    process.exit(1);
  });