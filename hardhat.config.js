require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-ethers");

const RINKEBY_URL = "https://rinkeby.infura.io/v3/YOUR_INFURA_PROJECT_ID";
const DEPLOYER_PRIVATE_KEY = "YOUR_DEPLOYER_PRIVATE_KEY";

module.exports = {
  solidity: "0.8.28",
  networks: {
    rinkeby: {
      url: RINKEBY_URL,
      accounts: [DEPLOYER_PRIVATE_KEY]
    },
    hardhat: {}
  }
};
