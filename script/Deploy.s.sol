// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import { console } from "forge-std/console.sol";

import { RainbowSuperToken } from "src/RainbowSuperToken.sol";
import { RainbowSuperTokenFactory } from "src/RainbowSuperTokenFactory.sol";

contract DeplyRainbow is Script {
    function run() public {
        address uniswapV3Factory = vm.envAddress("UNISWAP_V3_FACTORY");
        address nonfungiblePositionManager = vm.envAddress("NONFUNGIBLE_POSITION_MANAGER");
        address swapRouter = vm.envAddress("SWAP_ROUTER");

        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        if (block.chainid == 1) {
            weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        } else {
            weth = 0x4200000000000000000000000000000000000006;
        }

        console.log("Deploying RainbowSuperTokenFactory on chain ", block.chainid);
        RainbowSuperTokenFactory factory =
            new RainbowSuperTokenFactory(uniswapV3Factory, nonfungiblePositionManager, swapRouter, weth, "https://rainbow.me/tokens");
        console.log("Deployed RainbowSuperTokenFactory at ", address(factory));
    }
}
