// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";

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

    // Test metadata
    RainbowSuperToken.RainbowTokenMetadata public defaultMetadata;

    // Constants for testing
    uint256 constant INITIAL_SUPPLY = 10 ether;
    uint24 constant POOL_FEE = 10_000; // 1%

    function setUp() public virtual {
        vm.startPrank(owner);

        uint256 id;
        assembly {
            id := chainid()
        }

        //if (id == 31337) {
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
        //} else {
        //    weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
        //    factory = UniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        //    nftPositionManager = NonfungiblePositionManager(payable(0xC36442b4a4522E871399CD717aBDD847Ab11FE88));
        //}

        // Deploy Rainbow factory
        rainbowFactory = new RainbowSuperTokenFactory(address(factory), address(nftPositionManager), address(swapRouter), address(weth));
        vm.stopPrank();
    }
}
