const { ethers, upgrades } = require('hardhat')
const hre = require('hardhat')

async function main() {

  console.log('-- MutoPool CONTRACT Upgraded --');
  const MutoPool = await ethers.getContractFactory("MutoPool");
  // To Upgrade The Smart Contract You Have To Provide The Proxy Address In (proxyUpgrade) function
  const mutoPool = await upgrades.upgradeProxy("<Provide The Proxy Address Here>",MutoPool);
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