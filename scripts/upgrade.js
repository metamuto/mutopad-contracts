const { ethers, upgrades } = require('hardhat')
const hre = require('hardhat')

async function main() {

  console.log('-- MutoPool CONTRACT Upgraded --');
  const MutoPool = await ethers.getContractFactory("MutoPool");
  const mutoPool = await upgrades.upgradeProxy("0x50F48d98663084BfB6d18b9DE93B358181061F28",MutoPool);
  let mutoPoolImplementation = await upgrades.erc1967.getImplementationAddress(mutoPool.address);
  let mutoPoolProxyAdmin = await upgrades.erc1967.getAdminAddress(mutoPool.address);

  try{await hre.run("verify:verify", {address: mutoPoolImplementation});}catch(e){console.log(e.message)}
  
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