// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";
import { ISwapRouter } from "vendor/v3-periphery/interfaces/ISwapRouter.sol";
import { IUniswapV3Factory } from "vendor/v3-core/interfaces/IUniswapV3Factory.sol";
import { INonfungiblePositionManager } from "vendor/v3-periphery/interfaces/INonfungiblePositionManager.sol";
import { IWETH9 } from "vendor/v3-periphery/interfaces/external/IWETH9.sol";
import { RainbowSuperToken } from "src/RainbowSuperToken.sol";
import { RainbowSuperTokenFactory } from "src/RainbowSuperTokenFactory.sol";

contract ForkRainbowTest is Test {
    // Mainnet contract addresses
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant UNISWAP_SWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant UNISWAP_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // Mainnet WETH

    // Core contracts
    IUniswapV3Factory public factory;
    ISwapRouter public swapRouter;
    INonfungiblePositionManager public nftPositionManager;
    IWETH9 public weth;
    RainbowSuperTokenFactory public rainbowFactory;

    // Test accounts
    address public owner = makeAddr("owner");
    address public creator = makeAddr("creator");
    address public user = makeAddr("user");
    address public pot = makeAddr("pot"); 

    // Constants for testing
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether; // 1 million tokens
    uint256 constant BUY_AMOUNT = 1 ether; // 1 ETH to buy tokens
    int24 constant INITIAL_TICK = 0; // Starting tick for the liquidity position

    function setUp() public {
        // Fork Ethereum mainnet
        //vm.createSelectFork("https://eth-mainnet.g.alchemy.com/v2/h6emmq6kC1M6yx7CrQNm6svMt6i1");
        //vm.createSelectFork("https://eth.llamarpc.com");
        vm.createSelectFork("https://eth-mainnet.g.alchemy.com/v2/NH-zOEQiflbuqZZEL7UHeVkj9yZUG7_1");

        // Connect to existing contracts
        factory = IUniswapV3Factory(UNISWAP_V3_FACTORY);
        swapRouter = ISwapRouter(UNISWAP_SWAP_ROUTER);
        nftPositionManager = INonfungiblePositionManager(UNISWAP_POSITION_MANAGER);
        weth = IWETH9(WETH_ADDRESS);

        // Verify the tick spacing for our pool fee is as expected
        assertEq(factory.feeAmountTickSpacing(10_000), 200, "Tick spacing should be 200 for 1% fee");

        // Fund accounts
        vm.deal(creator, 10 ether);
        vm.deal(user, 10 ether);
        vm.deal(owner, 10 ether);

        // Deploy Rainbow factory
        vm.startPrank(owner);
        rainbowFactory =
            new RainbowSuperTokenFactory(UNISWAP_V3_FACTORY, address(pot), UNISWAP_POSITION_MANAGER, UNISWAP_SWAP_ROUTER, WETH_ADDRESS, "https://rainbow.me/tokens/");
        vm.stopPrank();
    }

    function testLaunchAndBuyToken() public {
        // Get initial balances
        uint256 creatorEthBefore = creator.balance;

        // Launch a new token as creator
        vm.startPrank(creator);

        // Create a deterministic salt for testing
        // We need to find a salt that produces a token address
        // that is lexicographically less than WETH address
        bytes32 salt;
        address predictedTokenAddress;
        uint256 counter = 0;

        do {
            salt = keccak256(abi.encodePacked(block.timestamp, creator, counter));
            predictedTokenAddress = rainbowFactory.predictTokenAddress(
                creator,
                "TestToken",
                "TEST",
                bytes32(0), // No merkle root
                INITIAL_SUPPLY,
                salt
            );
            counter++;
        } while (predictedTokenAddress > WETH_ADDRESS);

        console.log("Found valid salt after", counter, "attempts");
        console.log("Predicted token address:", predictedTokenAddress);

        // No merkle root for this test
        bytes32 merkleRoot = bytes32(0);

        // Launch and buy in one transaction
        RainbowSuperToken newToken = rainbowFactory.launchRainbowSuperTokenAndBuy{ value: BUY_AMOUNT }(
            "TestToken", "TEST", merkleRoot, INITIAL_SUPPLY, INITIAL_TICK, salt, creator, BUY_AMOUNT
        );

        // Verify the deployed address matches prediction
        assertEq(address(newToken), predictedTokenAddress, "Deployed address should match prediction");

        vm.stopPrank();

        // Verify token creation
        assertEq(newToken.name(), "TestToken");
        assertEq(newToken.symbol(), "TEST");

        // Verify creator spent ETH
        assertEq(creator.balance, creatorEthBefore - BUY_AMOUNT, "Creator should have spent ETH");

        // Verify creator received tokens
        uint256 creatorBalance = newToken.balanceOf(creator);
        assertTrue(creatorBalance > 0, "Creator should have tokens after buying");
    }
}
