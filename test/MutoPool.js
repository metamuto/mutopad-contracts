const { expect } = require("chai");

describe("Token contract", async function () {
    let MutoPool= "";
    it("Owner of the contract is Deployer", async function () {
        const [owner] = await ethers.getSigners();
        const Muto = await ethers.getContractFactory("MutoPool");
        MutoPool = await Muto.deploy({ gasLimit: 3 * 10 ** 7});
        const contractOwner = await MutoPool.owner();
        expect(contractOwner==="0x7ACf46627094FA89339DB5b2EB862F0E8Ea4D9fc");
    });
    it("User count should be equal to zero", async function(){
        const userCount = await MutoPool.numUsers()
        expect(userCount == 0)
    });
    it("Fee receiver user id should be equal to 1", async function(){
        const feeReceiverUserId = await MutoPool.feeReceiverUserId()
        expect(feeReceiverUserId == 1)
    });
    it("Auction counter should be equal to 0", async function(){
        const auctionCount = await MutoPool.auctionCounter()
        expect(auctionCount == 0)
    });
    it("Fee Denominator should be equal to 1000", async function(){
        const DENOMINATOR = await MutoPool.FEE_DENOMINATOR()
        expect(DENOMINATOR == 1000)
    });
    it("Fee Denominator should be equal to 1000", async function(){
        const DENOMINATOR = await MutoPool.getUserId("0x7ACf46627094FA89339DB5b2EB862F0E8Ea4D9fc")
        expect(DENOMINATOR == 1000)
    });
});