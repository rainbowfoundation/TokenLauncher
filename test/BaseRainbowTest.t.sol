// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { INonfungiblePositionManager } from "v3-periphery/interfaces/INonfungiblePositionManager.sol";
import { UniswapV3Factory } from "lib/v3-core/contracts/UniswapV3Factory.sol";
import { WETH } from "test/mocks/WETH.sol";
import { RainbowSuperToken } from "src/RainbowSuperToken.sol";
import { RainbowSuperTokenFactory } from "src/RainbowSuperTokenFactory.sol";

contract BaseRainbowTest is Test {
    // Core contracts
    UniswapV3Factory public factory;
    WETH public weth;
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
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether; // 1M tokens
    uint24 constant POOL_FEE = 10_000; // 1%

    function setUp() public virtual {
    }

    function testNothing() public {
        // Do nothing
    }
}
