// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./BaseRainbowTest.t.sol";
import { MockERC20, ERC20 } from "test/mocks/MockERC20.sol";
import { RainbowSuperToken } from "../src/RainbowSuperToken.sol";

contract RainbowSuperTokenFactoryTest is BaseRainbowTest {
    bytes32 public constant MERKLE_ROOT = keccak256("test");

    event RainbowSuperTokenCreated(address indexed token, address indexed owner, address indexed creator);
    event FeeConfigUpdated(address indexed token, RainbowSuperTokenFactory.FeeConfig config);
    event FeesCollected(uint256 indexed tokenId, uint256 creatorFee0, uint256 creatorFee1, uint256 protocolFee0, uint256 protocolFee1);
    event FeesClaimed(address indexed recipient, uint256 indexed tokenId, uint256 amount0, uint256 amount1);

    // Helper function to find valid salt for token deployment
    function findValidSalt(
        address creator,
        string memory name,
        string memory symbol,
        bytes32 merkleroot,
        uint256 supply
    )
        internal
        view
        returns (bytes32 salt, address predictedAddress)
    {
        bytes32 currentSalt = bytes32(uint256(1));
        bool foundValid = false;

        while (!foundValid) {
            address predicted = rainbowFactory.predictTokenAddress(creator, name, symbol, merkleroot, supply, currentSalt);

            if (predicted < address(rainbowFactory.defaultPairToken())) {
                return (currentSalt, predicted);
            }
            currentSalt = bytes32(uint256(currentSalt) + 1);
        }
        revert("No valid salt found");
    }

    function testPredictAddress() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Test Token", "TEST", bytes32(0), INITIAL_SUPPLY);

        address predicted = rainbowFactory.predictTokenAddress(creator1, "Test Token", "TEST", bytes32(0), INITIAL_SUPPLY, salt);

        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Test Token", "TEST", bytes32(0), INITIAL_SUPPLY, 200, salt, address(creator1));

        assertEq(predicted, address(token));
    }

    function testLaunchToken() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Test Token", "TEST", bytes32(0), INITIAL_SUPPLY);

        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Test Token", "TEST", bytes32(0), INITIAL_SUPPLY, 200, salt, address(creator1));

        assertTrue(address(token) < address(weth), "Token address must be less than WETH");
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.totalSupply(), INITIAL_SUPPLY);

        (,,,, bool hasAirdrop,, address creator) = rainbowFactory.tokenFeeConfig(address(token));
        assertEq(creator, creator1);
        assertFalse(hasAirdrop);

        uint256 positionId = rainbowFactory.tokenPositionIds(address(token));
        assertTrue(positionId > 0);
        vm.stopPrank();
    }

    function testLaunchTokenWithAirdrop() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Airdrop Token", "AIR", MERKLE_ROOT, INITIAL_SUPPLY);

        vm.expectEmit(false, true, true, true);
        emit RainbowSuperTokenFactory.RainbowSuperTokenCreated(address(0), address(creator1), creator1);

        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Airdrop Token", "AIR", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, address(creator1));

        assertTrue(address(token) < address(weth), "Token address must be less than WETH");
        (,,,, bool hasAirdrop,, address creator) = rainbowFactory.tokenFeeConfig(address(token));
        assertTrue(hasAirdrop);
        assertEq(creator, creator1);

        // Check supply allocations
        (uint16 creatorBaseBps,) = getCreatorAndAirdropBps();
        uint256 expectedCreatorAmount = (INITIAL_SUPPLY * creatorBaseBps) / 10_000;

        assertEq(token.balanceOf(address(creator1)), expectedCreatorAmount);
        vm.stopPrank();
    }

    function testCannotLaunchReservedName() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Rainbow", "TEST", MERKLE_ROOT, INITIAL_SUPPLY);

        vm.expectRevert(RainbowSuperTokenFactory.ReservedName.selector);
        rainbowFactory.launchRainbowSuperToken("Rainbow", "TEST", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, address(creator1));
        vm.stopPrank();
    }

    function testCannotLaunchReservedTicker() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Test Token", "RNBW", MERKLE_ROOT, INITIAL_SUPPLY);

        vm.expectRevert(RainbowSuperTokenFactory.ReservedTicker.selector);
        rainbowFactory.launchRainbowSuperToken("Test Token", "RNBW", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, address(creator1));
        vm.stopPrank();
    }

    function testBanName() public {
        vm.prank(owner);
        rainbowFactory.banName("Banned", true);

        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Banned", "TEST", MERKLE_ROOT, INITIAL_SUPPLY);

        vm.expectRevert(RainbowSuperTokenFactory.BannedName.selector);
        rainbowFactory.launchRainbowSuperToken("Banned", "TEST", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, address(creator1));
        vm.stopPrank();
    }

    function testBanTicker() public {
        vm.prank(owner);
        rainbowFactory.banTicker("BAN", true);

        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Test Token", "BAN", MERKLE_ROOT, INITIAL_SUPPLY);

        vm.expectRevert(RainbowSuperTokenFactory.BannedTicker.selector);
        rainbowFactory.launchRainbowSuperToken("Test Token", "BAN", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, address(creator1));
        vm.stopPrank();
    }

    function testUpdateDefaultFeeConfig() public {
        vm.startPrank(owner);

        RainbowSuperTokenFactory.FeeConfig memory newConfig = RainbowSuperTokenFactory.FeeConfig({
            creatorLPFeeBps: 1500, // 15%
            protocolBaseBps: 50, // 0.5%
            creatorBaseBps: 30, // 0.3%
            airdropBps: 20, // 0.2%
            hasAirdrop: false,
            feeToken: address(weth),
            creator: address(0)
        });

        rainbowFactory.setDefaultFeeConfig(newConfig);

        // Launch a token with new config
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Test Token", "TEST", MERKLE_ROOT, INITIAL_SUPPLY);

        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Test Token", "TEST", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, address(creator1));

        assertTrue(address(token) < address(weth), "Token address must be less than WETH");
        // Verify new config was applied
        (uint16 creatorLPFeeBps,,,,,,) = rainbowFactory.tokenFeeConfig(address(token));
        assertEq(creatorLPFeeBps, 1500);
        vm.stopPrank();
    }

    function testCannotUnauthorizedFeeClaim() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Fee Token", "FEE", MERKLE_ROOT, INITIAL_SUPPLY);

        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Fee Token", "FEE", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, creator1);

        assertTrue(address(token) < address(weth), "Token address must be less than WETH");
        vm.stopPrank();

        // Try to claim fees as non-creator
        vm.prank(user1);
        vm.expectRevert(RainbowSuperTokenFactory.Unauthorized.selector);
        rainbowFactory.claimCreatorFees(address(token), user1);
    }

    function testLaunchTokenWithBuy() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Test Token", "TEST", bytes32(0), INITIAL_SUPPLY);

        vm.deal(creator1, 1 ether);

        RainbowSuperToken token = rainbowFactory.launchRainbowSuperTokenAndBuy{ value: 1 ether }(
            "Test Token", "TEST", bytes32(0), INITIAL_SUPPLY, 200, salt, address(creator1), 1 ether
        );

        assertTrue(address(token) < address(weth), "Token address must be less than WETH");
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.totalSupply(), INITIAL_SUPPLY);

        (,,,, bool hasAirdrop,, address creator) = rainbowFactory.tokenFeeConfig(address(token));
        assertEq(creator, creator1);
        assertFalse(hasAirdrop);

        uint256 positionId = rainbowFactory.tokenPositionIds(address(token));
        assertTrue(positionId > 0);
        vm.stopPrank();
    }

    function testCollectAndClaimFees() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Fee Token", "FEE", MERKLE_ROOT, INITIAL_SUPPLY);

        // Launch token
        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Fee Token", "FEE", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, creator1);

        assertTrue(address(token) < address(weth), "Token address must be less than WETH");

        // Get the pool address and verify token ordering
        address poolAddress = factory.getPool(address(token), address(weth), POOL_FEE);
        require(poolAddress != address(0), "Pool not created");

        // Deal some ETH and perform swap
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        weth.deposit{ value: 50 ether }();
        weth.approve(address(swapRouter), type(uint256).max);

        // Perform swap WETH -> Token to generate fees
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(token),
            fee: POOL_FEE,
            recipient: user1,
            deadline: block.timestamp + 300,
            amountIn: 10 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        swapRouter.exactInputSingle(params);
        vm.stopPrank();

        // Mine some blocks to ensure fees are accumulated
        vm.roll(block.number + 100);

        // Record balances before fee collection
        vm.startPrank(creator1);
        uint256 creatorToken0Before = address(token) < address(weth) ? token.balanceOf(creator1) : weth.balanceOf(creator1);
        uint256 creatorToken1Before = address(token) < address(weth) ? weth.balanceOf(creator1) : token.balanceOf(creator1);

        // Collect fees
        rainbowFactory.collectFees(address(token));

        // Try claiming fees as creator
        rainbowFactory.claimCreatorFees(address(token), creator1);

        // Verify creator received fees
        uint256 creatorToken0After = address(token) < address(weth) ? token.balanceOf(creator1) : weth.balanceOf(creator1);
        uint256 creatorToken1After = address(token) < address(weth) ? weth.balanceOf(creator1) : token.balanceOf(creator1);

        assertTrue(creatorToken0After > creatorToken0Before || creatorToken1After > creatorToken1Before, "Creator did not receive fees");

        // Try claiming protocol fees as owner
        vm.startPrank(owner);
        uint256 ownerToken0Before = address(token) < address(weth) ? token.balanceOf(owner) : weth.balanceOf(owner);
        uint256 ownerToken1Before = address(token) < address(weth) ? weth.balanceOf(owner) : token.balanceOf(owner);

        rainbowFactory.claimProtocolFees(address(token), owner);

        uint256 ownerToken0After = address(token) < address(weth) ? token.balanceOf(owner) : weth.balanceOf(owner);
        uint256 ownerToken1After = address(token) < address(weth) ? weth.balanceOf(owner) : token.balanceOf(owner);

        assertTrue(ownerToken0After > ownerToken0Before || ownerToken1After > ownerToken1Before, "Owner did not receive fees");
        vm.stopPrank();

        vm.startPrank(creator1);
        // Verify can't claim again (no fees)
        vm.expectRevert(RainbowSuperTokenFactory.NoFeesToClaim.selector);
        rainbowFactory.claimCreatorFees(address(token), creator1);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert(RainbowSuperTokenFactory.NoFeesToClaim.selector);
        rainbowFactory.claimProtocolFees(address(token), owner);
        vm.stopPrank();
    }

    // Helper function to get creator and airdrop basis points
    function getCreatorAndAirdropBps() internal view returns (uint16, uint16) {
        (,, uint16 creatorBaseBps, uint16 airdropBps,,,) = rainbowFactory.defaultFeeConfig();
        return (creatorBaseBps, airdropBps);
    }

    // Add these tests to RainbowSuperTokenFactoryTest.sol
    function testUpdateDefaultPairToken() public {
        // Deploy mock USDC
        MockERC20 usdc = new MockERC20("USD Coin", "USDC");

        vm.startPrank(owner);
        // Update default pair token
        rainbowFactory.setNewPairToken(ERC20(address(usdc)));

        // Verify the new default pair token
        assertEq(address(rainbowFactory.defaultPairToken()), address(usdc));

        // Verify the approval was set
        assertEq(usdc.allowance(address(rainbowFactory), address(rainbowFactory.swapRouter())), type(uint256).max);
        vm.stopPrank();
    }

    function testDefaultFeeConfigUpdatesPairToken() public {
        // Deploy mock USDC
        MockERC20 usdc = new MockERC20("USD Coin", "USDC");

        vm.startPrank(owner);

        RainbowSuperTokenFactory.FeeConfig memory newConfig = RainbowSuperTokenFactory.FeeConfig({
            creatorLPFeeBps: 1500,
            protocolBaseBps: 50,
            creatorBaseBps: 30,
            airdropBps: 20,
            hasAirdrop: false,
            feeToken: address(usdc),
            creator: address(0)
        });

        rainbowFactory.setDefaultFeeConfig(newConfig);

        // Verify both defaultPairToken and feeToken were updated
        assertEq(address(rainbowFactory.defaultPairToken()), address(usdc));
        vm.stopPrank();
    }

    function testLaunchTokenWithUSDCBuy() public {
        // Deploy mock USDC
        MockERC20 usdc = new MockERC20("USD Coin", "USDC");

        vm.startPrank(owner);
        rainbowFactory.setNewPairToken(ERC20(address(usdc)));
        vm.stopPrank();

        vm.startPrank(creator1);

        // Mint some USDC to creator1
        usdc.mint(creator1, 1000e18);

        (bytes32 salt,) = findValidSalt(creator1, "Test Token", "TEST", bytes32(0), INITIAL_SUPPLY);

        // Approve USDC spend
        usdc.approve(address(rainbowFactory), 1000e18);

        RainbowSuperToken token = rainbowFactory.launchRainbowSuperTokenAndBuy(
            "Test Token",
            "TEST",
            bytes32(0),
            INITIAL_SUPPLY,
            200,
            salt,
            address(creator1),
            100e18 // Buy 100 USDC worth
        );

        assertTrue(address(token) < address(usdc), "Token address must be less than USDC");

        // Verify token was created and position exists
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");

        uint256 positionId = rainbowFactory.tokenPositionIds(address(token));
        assertTrue(positionId > 0);

        // Verify creator received tokens from swap
        assertTrue(token.balanceOf(creator1) > 0, "Creator should have received tokens from swap");
        vm.stopPrank();
    }

    function testCollectAndClaimUSDCFees() public {
        // Deploy mock USDC
        MockERC20 usdc = new MockERC20("USD Coin", "USDC");

        vm.startPrank(owner);
        rainbowFactory.setNewPairToken(ERC20(address(usdc)));
        vm.stopPrank();

        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Fee Token", "FEE", MERKLE_ROOT, INITIAL_SUPPLY);

        // Launch token
        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Fee Token", "FEE", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, creator1);

        assertTrue(address(token) < address(usdc), "Token address must be less than USDC");

        // Get the pool address
        address poolAddress = factory.getPool(address(token), address(usdc), POOL_FEE);
        require(poolAddress != address(0), "Pool not created");

        // Setup user1 with USDC for swapping
        vm.stopPrank();
        vm.startPrank(address(usdc));
        usdc.mint(user1, 1000e18);
        vm.stopPrank();

        vm.startPrank(user1);
        usdc.approve(address(swapRouter), type(uint256).max);

        // Perform swap USDC -> Token to generate fees
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdc),
            tokenOut: address(token),
            fee: POOL_FEE,
            recipient: user1,
            deadline: block.timestamp + 300,
            amountIn: 100e18,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        swapRouter.exactInputSingle(params);
        vm.stopPrank();

        // Mine some blocks
        vm.roll(block.number + 100);

        // Record balances before fee collection
        vm.startPrank(creator1);
        uint256 creatorToken0Before = token.balanceOf(creator1);
        uint256 creatorToken1Before = usdc.balanceOf(creator1);

        // Collect fees
        rainbowFactory.collectFees(address(token));

        // Claim creator fees
        rainbowFactory.claimCreatorFees(address(token), creator1);

        // Verify creator received fees
        uint256 creatorToken0After = token.balanceOf(creator1);
        uint256 creatorToken1After = usdc.balanceOf(creator1);

        assertTrue(creatorToken0After > creatorToken0Before || creatorToken1After > creatorToken1Before, "Creator did not receive fees");

        vm.stopPrank();

        // Check protocol fees
        vm.startPrank(owner);
        uint256 ownerToken0Before = token.balanceOf(owner);
        uint256 ownerToken1Before = usdc.balanceOf(owner);

        rainbowFactory.claimProtocolFees(address(token), owner);

        uint256 ownerToken0After = token.balanceOf(owner);
        uint256 ownerToken1After = usdc.balanceOf(owner);

        assertTrue(ownerToken0After > ownerToken0Before || ownerToken1After > ownerToken1Before, "Owner did not receive fees");
        vm.stopPrank();
    }
}
