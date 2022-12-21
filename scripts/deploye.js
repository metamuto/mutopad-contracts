const { ethers } = require('hardhat');
/** This is a function used to deploy contract */
const hre = require('hardhat');

async function main() {
  const EasyAuction = await hre.ethers.getContractFactory('EasyAuction');
  const _EasyAuction = await EasyAuction.deploy();
  console.log(
    'EasyAuction deployed to:',
    _EasyAuction.address,
  );
}

main().
  then(() => process.exit(0)).
  catch((error) => {
    console.error(error);
    process.exit(1);
  });