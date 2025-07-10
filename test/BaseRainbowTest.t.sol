// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";
import { IWETH9 } from "lib/v4-periphery/src/interfaces/external/IWETH9.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import { IUniversalRouter } from "vendor/universal-router/IUniversalRouter.sol";
import { RainbowSuperTokenFactory } from "src/RainbowSuperTokenFactory.sol";

contract BaseRainbowTest is Test {
    // V4 contracts (mainnet addresses)
    IPoolManager public poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager public positionManager = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IUniversalRouter public universalRouter = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    address public permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    IWETH9 public weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    
    // Our factory contract
    RainbowSuperTokenFactory public rainbowFactory;
    
    // Test accounts
    address public owner = makeAddr("owner");
    address public creator1 = makeAddr("creator1");
    address public creator2 = makeAddr("creator2");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public pot = makeAddr("pot");

    // Constants for testing
    uint256 constant INITIAL_SUPPLY = 10 ether;
    uint24 constant POOL_FEE = 10_000; // 1%
    
    function setUp() public virtual {
        // Fork mainnet at a recent block
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), 18900000);
        
        // Deploy only your factory
        vm.prank(owner);
        rainbowFactory = new RainbowSuperTokenFactory(
            address(poolManager),
            address(positionManager),
            address(universalRouter),
            address(permit2),
            address(pot),
            address(weth),
            "https://rainbow.me/tokens"
        );
        
        // Fund test accounts
        vm.deal(creator1, 100 ether);
        vm.deal(user1, 100 ether);
    }
}