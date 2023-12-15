
const hre = require("hardhat");

async function main() {
  this.accounts = await ethers.getSigners()
  this.owner = this.accounts[0].address

  const arbiEndPoint = '0x3c2269811836af69497E5F486A85D7316753cf62'
  const mainnetChainId = 101
  const peusd = await ethers.getContractFactory("PeUSD")
  const peusdMainnet = '0xD585aaafA2B58b1CD75092B51ade9Fa4Ce52F247'

  this.peusd = await peusd.deploy(8, arbiEndPoint)

  console.log('peusd arbi', this.peusd.address)


  await this.peusd.setTrustedRemote(
    mainnetChainId,
    ethers.utils.solidityPack(["address", "address"], [peusdMainnet, this.peusd.address])
  )

  console.log('getTrustedRemoteAddress', await this.peusd.getTrustedRemoteAddress(mainnetChainId))

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
