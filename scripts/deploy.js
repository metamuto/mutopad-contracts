const { ethers, upgrades } = require('hardhat')
const hre = require('hardhat')

async function main() {

  console.log('-- MutoPool CONTRACT --');
  const MutoPool = await ethers.getContractFactory("MutoPool");
  const mutoPool = await upgrades.deployProxy(MutoPool);
  await mutoPool.deployed();
  await mutoPool.deployTransaction.wait(2);
  let mutoPoolImplementation = await upgrades.erc1967.getImplementationAddress(mutoPool.address);
  let mutoPoolProxyAdmin = await upgrades.erc1967.getAdminAddress(mutoPool.address);
  
  console.log('MutoPool TOKEN CONTRACT: ',mutoPool.address);
  console.log('IMPLEMENTATION: ',mutoPoolImplementation);
  console.log('PROXY ADMIN: ',mutoPoolProxyAdmin);

}

main().
  then(() => process.exit(0)).
  catch((error) => {
    console.error(error);
    process.exit(1);
  });