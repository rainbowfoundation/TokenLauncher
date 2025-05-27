# 🌈 Rainbow Token Launcher 🌈

The rainbow token launcher is a very simple system composed of a couple core contracts, first RainbowSuperToken, and RainbowSuperTokenFactory.

## RainbowSuperTokenFactory

The RainbowSuperTokenFactory is the main contract in the system, and it has most of the responsibilities. It first launches token, allocates their supply's, handles the distribution of their LP fees, and ensures the protocol receives its tokens.

It holds all Uni-v3 positions which provide liquidity for the tokens, which are unable to be transferred out, but their fees can be claimed by any interested party, but are not transfered from the factory until requested by each party.

### Deployment Addresses
- Ethereum Mainnet: [0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229](https://etherscan.io/address/0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229)
- Optimism Mainnet: [0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229](https://optimistic.etherscan.io/address/0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229)
- Arbitrum One: [0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229](https://arbiscan.io/address/0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229)
- Polygon Mainnet: [0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229](https://polygonscan.com/address/0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229)
- Base Mainnet: [0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229](https://basescan.org/address/0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229)
- BSC Mainnet: [0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229](https://bscscan.com/address/0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229)
- AVAX Mainnet: [0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229](https://snowtrace.io/address/0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229)
- Blast Mainnet: [0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229](https://blastscan.io/address/0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229)
- Ink Mainnet: [0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229](https://explorer.inkonchain.com/address/0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229)
- Berachain Mainnet: [0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229](https://berascan.com/address/0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229)
- Unichain Mainnet: [0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229](https://unichain.blockscout.com/address/0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229)
- Zora Mainnet: [0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229](https://explorer.zora.energy/address/0x48033c4a1c834AA1aEf91ef6FBfa8fD68fb54229)

## RainbowSuperToken

The RainbowSuperToken is a SuperchainERC20 token, so it can be easily bridged within the Superchain. It also stores a URI for an image, a longform description, a farcaster channel and profile url, and a telegram url. Additionally, at launch it can be supplied with a Merkle Root that will let users claim tokens up to a capped supply, on a first come, first serve basis. 

## The Repository

You can install all dependencies via `forge install` and run tests via `forge test`, all Uniswap-v3 dependencies are vendored at a specific solc 0.8 version for compatibility.
