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

    function testLaunchFromOtherChain() public {
        vm.startPrank(creator1);
        (bytes32 salt,) = findValidSalt(creator1, "Airdrop Token", "AIR", MERKLE_ROOT, INITIAL_SUPPLY);

        vm.chainId(1);

        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Airdrop Token", "AIR", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, address(creator1));

        vm.chainId(2);

        vm.expectRevert(); // CreateCollision because we are not using a seperate fork
        RainbowSuperToken token2 =
            rainbowFactory.launchFromOtherChain("Airdrop Token", "AIR", MERKLE_ROOT, INITIAL_SUPPLY, salt, creator1, 1, 50_000_000_000_000_000);
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
        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(token),
            fee: POOL_FEE,
            recipient: user1,
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
        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: address(usdc),
            tokenOut: address(token),
            fee: POOL_FEE,
            recipient: user1,
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

    function testUpdatedSupplyAllocationLogic() public {
        vm.startPrank(owner);

        // Get default fee config values
        (, uint16 protocolBaseBps, uint16 creatorBaseBps, uint16 airdropBps,,,) = rainbowFactory.defaultFeeConfig();

        // Set a specific protocol owner address to test allocations
        address protocolOwner = address(0xDEAD);

        vm.stopPrank();

        // Test token without airdrop - creator should get both creator and airdrop allocations
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "No Airdrop Updated", "NAIR", bytes32(0), INITIAL_SUPPLY);
        RainbowSuperToken tokenNoAirdrop = rainbowFactory.launchRainbowSuperToken(
            "No Airdrop Updated",
            "NAIR",
            bytes32(0), // No merkleroot means no airdrop
            INITIAL_SUPPLY,
            200,
            salt,
            address(creator1)
        );

        // Calculate expected allocations without airdrop
        // When no airdrop, creator should get their base allocation PLUS the airdrop allocation
        uint256 expectedCreatorAmount = (INITIAL_SUPPLY * creatorBaseBps) / 10_000 + (INITIAL_SUPPLY * airdropBps) / 10_000;
        uint256 expectedProtocolAmount = (INITIAL_SUPPLY * protocolBaseBps) / 10_000;

        // Check creator allocation includes both creator and airdrop portions
        assertEq(tokenNoAirdrop.balanceOf(creator1), expectedCreatorAmount, "Creator should receive both creator and airdrop allocations when no airdrop");

        // Check protocol allocation
        uint256 tokenId = rainbowFactory.tokenPositionIds(address(tokenNoAirdrop));
        (uint128 protocolUnclaimed0, uint128 protocolUnclaimed1) = rainbowFactory.protocolUnclaimedFees(tokenId);
        assertEq(uint256(protocolUnclaimed0), expectedProtocolAmount, "Protocol allocation incorrect");

        vm.stopPrank();

        // Test protocol owner allocation
        vm.startPrank(owner);

        // Claim protocol fees to the protocol owner
        uint256 protocolOwnerBalanceBefore = tokenNoAirdrop.balanceOf(protocolOwner);
        rainbowFactory.claimProtocolFees(address(tokenNoAirdrop), protocolOwner);
        uint256 protocolOwnerBalanceAfter = tokenNoAirdrop.balanceOf(protocolOwner);

        // Verify protocol owner received the correct allocation
        assertEq(protocolOwnerBalanceAfter - protocolOwnerBalanceBefore, expectedProtocolAmount, "Protocol owner should receive protocol allocation");

        // Test with modified fee configuration
        RainbowSuperTokenFactory.FeeConfig memory newConfig = RainbowSuperTokenFactory.FeeConfig({
            creatorLPFeeBps: 2000,
            protocolBaseBps: 200, // 2% to protocol
            creatorBaseBps: 100, // 1% to creator
            airdropBps: 50, // 0.5% to airdrop
            hasAirdrop: false,
            feeToken: address(weth),
            creator: address(0)
        });

        rainbowFactory.setDefaultFeeConfig(newConfig);
        vm.stopPrank();

        // Test new token with updated fee config
        vm.startPrank(creator2);

        (salt,) = findValidSalt(creator2, "Updated Fee Token", "UFT", bytes32(0), INITIAL_SUPPLY);
        RainbowSuperToken updatedFeeToken = rainbowFactory.launchRainbowSuperToken(
            "Updated Fee Token",
            "UFT",
            bytes32(0), // No airdrop
            INITIAL_SUPPLY,
            200,
            salt,
            address(creator2)
        );

        // With new fee config and no airdrop, creator should get their allocation + airdrop allocation
        expectedCreatorAmount = (INITIAL_SUPPLY * 100) / 10_000 + (INITIAL_SUPPLY * 50) / 10_000; // 1% + 0.5%
        expectedProtocolAmount = (INITIAL_SUPPLY * 200) / 10_000; // 2%

        // Check creator allocation includes both creator and airdrop portions with new fees
        assertEq(updatedFeeToken.balanceOf(creator2), expectedCreatorAmount, "Creator should receive both creator and airdrop allocations with new fees");

        // Check protocol allocation with new fees
        tokenId = rainbowFactory.tokenPositionIds(address(updatedFeeToken));
        (protocolUnclaimed0, protocolUnclaimed1) = rainbowFactory.protocolUnclaimedFees(tokenId);
        assertEq(uint256(protocolUnclaimed0), expectedProtocolAmount, "Protocol allocation incorrect with new fees");

        vm.stopPrank();

        // Verify protocol owner allocation with new fees
        vm.startPrank(owner);
        protocolOwnerBalanceBefore = updatedFeeToken.balanceOf(protocolOwner);
        rainbowFactory.claimProtocolFees(address(updatedFeeToken), protocolOwner);
        protocolOwnerBalanceAfter = updatedFeeToken.balanceOf(protocolOwner);

        assertEq(
            protocolOwnerBalanceAfter - protocolOwnerBalanceBefore,
            expectedProtocolAmount,
            "Protocol owner should receive correct protocol allocation with new fees"
        );

        vm.stopPrank();
    }

    function testFuzz_CalculateSupplyAllocation(
        uint16 creatorLPFeeBps,
        uint16 protocolBaseBps,
        uint16 creatorBaseBps,
        uint16 airdropBps,
        uint256 initialSupply
    ) public {
        // Bound the inputs to reasonable ranges
        creatorLPFeeBps = uint16(bound(creatorLPFeeBps, 0, 10_000));
        protocolBaseBps = uint16(bound(protocolBaseBps, 0, 5_000));
        creatorBaseBps = uint16(bound(creatorBaseBps, 0, 5_000));
        airdropBps = uint16(bound(airdropBps, 0, 5_000));
        initialSupply = bound(initialSupply, 1 ether, 1_000_000 ether);
        
        // Skip if total basis points would exceed 10_000 (100%)
        vm.assume(protocolBaseBps + creatorBaseBps + airdropBps <= 10_000);
        
        // Set the fee configuration
        vm.startPrank(owner);
        RainbowSuperTokenFactory.FeeConfig memory newConfig = RainbowSuperTokenFactory.FeeConfig({
            creatorLPFeeBps: creatorLPFeeBps,
            protocolBaseBps: protocolBaseBps,
            creatorBaseBps: creatorBaseBps,
            airdropBps: airdropBps,
            hasAirdrop: false,
            feeToken: address(weth),
            creator: address(0)
        });
        
        rainbowFactory.setDefaultFeeConfig(newConfig);
        vm.stopPrank();
        
        // Test both with and without airdrop
        _testAllocationWithConfig(initialSupply, false, creatorBaseBps, protocolBaseBps, airdropBps);
        _testAllocationWithConfig(initialSupply, true, creatorBaseBps, protocolBaseBps, airdropBps);
    }

    // Helper function to test allocation with specific configuration
    function _testAllocationWithConfig(
        uint256 supply,
        bool hasAirdrop,
        uint16 creatorBaseBps, 
        uint16 protocolBaseBps,
        uint16 airdropBps
    ) internal {
        vm.startPrank(creator1);
        
        bytes32 merkleroot = hasAirdrop ? bytes32(keccak256("test")) : bytes32(0);
        string memory tokenName = hasAirdrop ? "Airdrop Test" : "No Airdrop Test";
        string memory tokenSymbol = hasAirdrop ? "AIR" : "NAIR";
        
        (bytes32 salt,) = findValidSalt(creator1, tokenName, tokenSymbol, merkleroot, supply);
        
        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken(
            tokenName, 
            tokenSymbol, 
            merkleroot, 
            supply, 
            200, 
            salt, 
            address(creator1)
        );
        
        // Calculate expected allocations
        uint256 expectedProtocolAmount = (supply * protocolBaseBps) / 10_000;
        
        uint256 expectedCreatorAmount;
        if (hasAirdrop) {
            // With airdrop, creator only gets their base allocation
            expectedCreatorAmount = (supply * creatorBaseBps) / 10_000;
        } else {
            // Without airdrop, creator gets their base allocation AND the airdrop allocation
            expectedCreatorAmount = (supply * creatorBaseBps) / 10_000 + 
                                    (supply * airdropBps) / 10_000;
        }
        
        uint256 expectedAirdropAmount = hasAirdrop ? (supply * airdropBps) / 10_000 : 0;
        
        // Check creator allocation
        assertApproxEqAbs(
            token.balanceOf(creator1), 
            expectedCreatorAmount, 
            1, // Allow 1 wei difference for rounding
            "Creator allocation incorrect"
        );
        
        // Check protocol allocation
        uint256 tokenId = rainbowFactory.tokenPositionIds(address(token));
        (uint128 protocolUnclaimed0, uint128 protocolUnclaimed1) = rainbowFactory.protocolUnclaimedFees(tokenId);
        
        // For our test setup, the token address is always less than WETH, so unclaimed0 is the token
        assertApproxEqAbs(
            uint256(protocolUnclaimed0), 
            expectedProtocolAmount, 
            1, // Allow 1 wei difference for rounding
            "Protocol allocation incorrect"
        );
        vm.stopPrank();
    }

    function testFuzz_ProtocolOwnerAllocation(
        uint16 protocolBaseBps,
        uint256 initialSupply
    ) public {
        protocolBaseBps = uint16(bound(protocolBaseBps, 1, 1_000)); // 0.01% to 10%
        initialSupply = bound(initialSupply, 1 ether, 1_000_000 ether);
        
        // Set a specific protocol fee
        vm.startPrank(owner);
        RainbowSuperTokenFactory.FeeConfig memory newConfig = RainbowSuperTokenFactory.FeeConfig({
            creatorLPFeeBps: 2000,
            protocolBaseBps: protocolBaseBps,
            creatorBaseBps: 100,
            airdropBps: 50,
            hasAirdrop: false,
            feeToken: address(weth),
            creator: address(0)
        });
        
        rainbowFactory.setDefaultFeeConfig(newConfig);
        vm.stopPrank();
        
        // Launch a token with the new configuration
        vm.startPrank(creator1);
        (bytes32 salt,) = findValidSalt(creator1, "Protocol Test", "PROT", bytes32(0), initialSupply);
        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken(
            "Protocol Test", 
            "PROT", 
            bytes32(0), 
            initialSupply, 
            200, 
            salt, 
            address(creator1)
        );
        vm.stopPrank();
        
        // Calculate expected protocol fee
        uint256 expectedProtocolAmount = (initialSupply * protocolBaseBps) / 10_000;
        
        // Claim protocol fees to a specific address
        address protocolReceiver = address(0xBEEF);
        
        uint256 balanceBefore = token.balanceOf(protocolReceiver);
        
        vm.prank(owner);
        rainbowFactory.claimProtocolFees(address(token), protocolReceiver);
        
        uint256 balanceAfter = token.balanceOf(protocolReceiver);
        
        // Verify the protocol receiver got the expected amount
        assertApproxEqAbs(
            balanceAfter - balanceBefore, 
            expectedProtocolAmount, 
            1, // Allow 1 wei difference for rounding
            "Protocol receiver didn't get expected allocation"
        );
    }

    function testFuzz_InvalidFeeSplitReverts() public {
        vm.startPrank(owner);
        
        uint16 invalidCreatorLPFeeBps = 10_001; // Just over the limit
        
        RainbowSuperTokenFactory.FeeConfig memory invalidLPConfig = RainbowSuperTokenFactory.FeeConfig({
            creatorLPFeeBps: invalidCreatorLPFeeBps, // This exceeds 100%
            protocolBaseBps: 100,
            creatorBaseBps: 100,
            airdropBps: 50,
            hasAirdrop: false,
            feeToken: address(weth),
            creator: address(0)
        });
        
        vm.expectRevert(RainbowSuperTokenFactory.InvalidFeeSplit.selector);
        rainbowFactory.setDefaultFeeConfig(invalidLPConfig);
        
        vm.stopPrank();
    }

    function testFuzz_InvalidSupplyAllocation(
        uint16 protocolBaseBps,
        uint16 creatorBaseBps,
        uint16 airdropBps
    ) public {
        // Testing InvalidSupplyAllocation error
        // Bound the inputs to ensure they can sum to more than 10_000
        protocolBaseBps = uint16(bound(uint256(protocolBaseBps), 3_334, 5_000));
        creatorBaseBps = uint16(bound(uint256(creatorBaseBps), 3_334, 5_000));
        airdropBps = uint16(bound(uint256(airdropBps), 3_334, 5_000));
        
        // With these bounds, the sum will always be greater than 10_000
        // (at minimum: 3_334 + 3_334 + 3_334 = 10_002)
        
        vm.startPrank(owner);
        RainbowSuperTokenFactory.FeeConfig memory invalidBaseConfig = RainbowSuperTokenFactory.FeeConfig({
            creatorLPFeeBps: 2000, // This is valid
            protocolBaseBps: protocolBaseBps,
            creatorBaseBps: creatorBaseBps,
            airdropBps: airdropBps,
            hasAirdrop: false,
            feeToken: address(weth),
            creator: address(0)
        });
        
        vm.expectRevert(RainbowSuperTokenFactory.InvalidSupplyAllocation.selector);
        rainbowFactory.setDefaultFeeConfig(invalidBaseConfig);
        
        vm.stopPrank();
    }

    function testFuzz_AllocationWithZeroSupply(uint16 feeBps) public {
        // Make sure feeBps is within valid range and total allocation doesn't exceed 10_000
        feeBps = uint16(bound(uint256(feeBps), 0, 9_850)); // Leave room for creatorBaseBps and airdropBps
        
        // Calculate creator and airdrop bps to ensure total is valid
        uint16 creatorBaseBps = 100;
        uint16 airdropBps = 50;
        
        vm.assume(feeBps + creatorBaseBps + airdropBps <= 10_000);
        
        vm.startPrank(owner);
        RainbowSuperTokenFactory.FeeConfig memory config = RainbowSuperTokenFactory.FeeConfig({
            creatorLPFeeBps: 2000,
            protocolBaseBps: feeBps,
            creatorBaseBps: creatorBaseBps,
            airdropBps: airdropBps,
            hasAirdrop: false,
            feeToken: address(weth),
            creator: address(0)
        });
        
        rainbowFactory.setDefaultFeeConfig(config);
        vm.stopPrank();
        
        vm.startPrank(creator1);
        (bytes32 salt,) = findValidSalt(creator1, "Zero Supply", "ZERO", bytes32(0), 0);
        
        vm.expectRevert(RainbowSuperTokenFactory.ZeroSupply.selector);
        rainbowFactory.launchRainbowSuperToken(
            "Zero Supply", 
            "ZERO", 
            bytes32(0), 
            0, // Zero supply
            200, 
            salt, 
            address(creator1)
        );
        
        vm.stopPrank();
    }
}
