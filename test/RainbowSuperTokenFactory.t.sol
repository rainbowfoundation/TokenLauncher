// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./BaseRainbowTest.t.sol";
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
        uint256 supply,
        string memory tokenURI
    )
        internal
        view
        returns (bytes32 salt, address predictedAddress)
    {
        bytes32 currentSalt = bytes32(uint256(1));
        bool foundValid = false;

        while (!foundValid) {
            address predicted = rainbowFactory.predictTokenAddress(creator, name, symbol, merkleroot, supply, currentSalt, tokenURI);

            if (predicted < address(weth)) {
                return (currentSalt, predicted);
            }
            currentSalt = bytes32(uint256(currentSalt) + 1);
        }
        revert("No valid salt found");
    }

    function testPredictAddress() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Test Token", "TEST", bytes32(0), INITIAL_SUPPLY, "https://rainbow.me/testMetadata");

        address predicted = rainbowFactory.predictTokenAddress(creator1, "Test Token", "TEST", bytes32(0), INITIAL_SUPPLY, salt, "https://rainbow.me/testMetadata");

        RainbowSuperToken token =
            rainbowFactory.launchRainbowSuperToken("Test Token", "TEST", bytes32(0), INITIAL_SUPPLY, 200, salt, address(creator1), "https://rainbow.me/testMetadata");

        assertEq(predicted, address(token));
    }

    function testLaunchToken() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Test Token", "TEST", bytes32(0), INITIAL_SUPPLY, "https://rainbow.me/testMetadata");

        RainbowSuperToken token =
            rainbowFactory.launchRainbowSuperToken("Test Token", "TEST", bytes32(0), INITIAL_SUPPLY, 200, salt, address(creator1), "https://rainbow.me/testMetadata");

        assertTrue(address(token) < address(weth), "Token address must be less than WETH");
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.totalSupply(), INITIAL_SUPPLY);

        (,,,, bool hasAirdrop, address creator) = rainbowFactory.tokenFeeConfig(address(token));
        assertEq(creator, creator1);
        assertFalse(hasAirdrop);

        uint256 positionId = rainbowFactory.tokenPositionIds(address(token));
        assertTrue(positionId > 0);
        vm.stopPrank();
    }

    function testLaunchTokenWithAirdrop() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Airdrop Token", "AIR", MERKLE_ROOT, INITIAL_SUPPLY, "https://rainbow.me/testMetadata");

        vm.expectEmit(false, true, true, true);
        emit RainbowSuperTokenFactory.RainbowSuperTokenCreated(address(0), address(creator1), creator1);

        RainbowSuperToken token =
            rainbowFactory.launchRainbowSuperToken("Airdrop Token", "AIR", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, address(creator1), "https://rainbow.me/testMetadata");

        assertTrue(address(token) < address(weth), "Token address must be less than WETH");
        (,,,, bool hasAirdrop, address creator) = rainbowFactory.tokenFeeConfig(address(token));
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

        (bytes32 salt,) = findValidSalt(creator1, "Rainbow", "TEST", MERKLE_ROOT, INITIAL_SUPPLY, "https://rainbow.me/testMetadata");

        vm.expectRevert(RainbowSuperTokenFactory.ReservedName.selector);
        rainbowFactory.launchRainbowSuperToken("Rainbow", "TEST", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, address(creator1), "https://rainbow.me/testMetadata");
        vm.stopPrank();
    }

    function testCannotLaunchReservedTicker() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Test Token", "RNBW", MERKLE_ROOT, INITIAL_SUPPLY, "https://rainbow.me/testMetadata");

        vm.expectRevert(RainbowSuperTokenFactory.ReservedTicker.selector);
        rainbowFactory.launchRainbowSuperToken("Test Token", "RNBW", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, address(creator1), "https://rainbow.me/testMetadata");
        vm.stopPrank();
    }

    function testBanName() public {
        vm.prank(owner);
        rainbowFactory.banName("Banned", true);

        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Banned", "TEST", MERKLE_ROOT, INITIAL_SUPPLY, "https://rainbow.me/testMetadata");

        vm.expectRevert(RainbowSuperTokenFactory.BannedName.selector);
        rainbowFactory.launchRainbowSuperToken("Banned", "TEST", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, address(creator1), "https://rainbow.me/testMetadata");
        vm.stopPrank();
    }

    function testBanTicker() public {
        vm.prank(owner);
        rainbowFactory.banTicker("BAN", true);

        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Test Token", "BAN", MERKLE_ROOT, INITIAL_SUPPLY, "https://rainbow.me/testMetadata");

        vm.expectRevert(RainbowSuperTokenFactory.BannedTicker.selector);
        rainbowFactory.launchRainbowSuperToken("Test Token", "BAN", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, address(creator1), "https://rainbow.me/testMetadata");
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
            creator: address(0)
        });

        rainbowFactory.setDefaultFeeConfig(newConfig);

        // Launch a token with new config
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Test Token", "TEST", MERKLE_ROOT, INITIAL_SUPPLY, "https://rainbow.me/testMetadata");

        RainbowSuperToken token =
            rainbowFactory.launchRainbowSuperToken("Test Token", "TEST", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, address(creator1), "https://rainbow.me/testMetadata");

        assertTrue(address(token) < address(weth), "Token address must be less than WETH");
        // Verify new config was applied
        (uint16 creatorLPFeeBps,,,,,) = rainbowFactory.tokenFeeConfig(address(token));
        assertEq(creatorLPFeeBps, 1500);
        vm.stopPrank();
    }

    function testCannotUnauthorizedFeeClaim() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Fee Token", "FEE", MERKLE_ROOT, INITIAL_SUPPLY, "https://rainbow.me/testMetadata");

        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Fee Token", "FEE", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, creator1, "https://rainbow.me/testMetadata");

        assertTrue(address(token) < address(weth), "Token address must be less than WETH");
        vm.stopPrank();

        // Try to claim fees as non-creator
        vm.prank(user1);
        vm.expectRevert(RainbowSuperTokenFactory.Unauthorized.selector);
        rainbowFactory.claimCreatorFees(address(token), user1);
    }

    function testLaunchTokenWithBuy() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Test Token", "TEST", bytes32(0), INITIAL_SUPPLY, "https://rainbow.me/testMetadata");

        vm.deal(creator1, 1 ether);

        RainbowSuperToken token = rainbowFactory.launchRainbowSuperTokenAndBuy{ value: 1 ether }(
            "Test Token", "TEST", bytes32(0), INITIAL_SUPPLY, 200, salt, address(creator1), "https://rainbow.me/testMetadata"
        );

        assertTrue(address(token) < address(weth), "Token address must be less than WETH");
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.totalSupply(), INITIAL_SUPPLY);

        (,,,, bool hasAirdrop, address creator) = rainbowFactory.tokenFeeConfig(address(token));
        assertEq(creator, creator1);
        assertFalse(hasAirdrop);

        uint256 positionId = rainbowFactory.tokenPositionIds(address(token));
        assertTrue(positionId > 0);
        vm.stopPrank();
    }

    function testCollectAndClaimFees() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Fee Token", "FEE", MERKLE_ROOT, INITIAL_SUPPLY, "https://rainbow.me/testMetadata");

        // Launch token
        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Fee Token", "FEE", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, creator1, "https://rainbow.me/testMetadata");

        assertTrue(address(token) < address(weth), "Token address must be less than WETH");
        uint256 tokenId = rainbowFactory.tokenPositionIds(address(token));

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
        (,, uint16 creatorBaseBps, uint16 airdropBps,,) = rainbowFactory.defaultFeeConfig();
        return (creatorBaseBps, airdropBps);
    }
}
