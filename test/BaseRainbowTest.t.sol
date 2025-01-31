// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";

import { ISwapRouter } from "vendor/v3-periphery/interfaces/ISwapRouter.sol";
import { Test } from "forge-std/Test.sol";
import { SwapRouter } from "vendor/v3-periphery/SwapRouter.sol";
import { NonfungiblePositionManager } from "vendor/v3-periphery/NonfungiblePositionManager.sol";
import { UniswapV3Factory } from "vendor/v3-core/UniswapV3Factory.sol";
import { WETH } from "test/mocks/WETH.sol";
import { RainbowSuperToken } from "src/RainbowSuperToken.sol";
import { RainbowSuperTokenFactory } from "src/RainbowSuperTokenFactory.sol";

contract BaseRainbowTest is Test {
    // Core contracts
    NonfungiblePositionManager public nftPositionManager;
    UniswapV3Factory public factory;
    WETH public weth;
    SwapRouter public swapRouter;
    RainbowSuperTokenFactory public rainbowFactory;

    // Test accounts
    address public owner = makeAddr("owner");
    address public creator1 = makeAddr("creator1");
    address public creator2 = makeAddr("creator2");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    // Constants for testing
    uint256 constant INITIAL_SUPPLY = 10 ether;
    uint24 constant POOL_FEE = 10_000; // 1%

    function setUp() public virtual {
        vm.startPrank(owner);

        uint256 id;
        assembly {
            id := chainid()
        }

        // Deploy Uniswap V3 contracts
        factory = new UniswapV3Factory();
        weth = new WETH();

        swapRouter = new SwapRouter(address(factory), address(weth));

        // Deploy position manager
        nftPositionManager = new NonfungiblePositionManager(
            address(factory),
            address(weth),
            address(0) // No descriptor needed for testing
        );

        // Deploy Rainbow factory
        rainbowFactory = new RainbowSuperTokenFactory(address(factory), address(nftPositionManager), address(swapRouter), address(weth));
        vm.stopPrank();
    }
}
