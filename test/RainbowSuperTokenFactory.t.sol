// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./BaseRainbowTest.t.sol";
import { MockERC20, ERC20 } from "test/mocks/MockERC20.sol";
import { RainbowSuperToken } from "../src/RainbowSuperToken.sol";
import { Merkle } from "lib/murky/src/Merkle.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Actions } from "lib/v4-periphery/src/libraries/Actions.sol";
import { Commands } from "vendor/universal-router/Commands.sol";
import { IV4Router } from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";

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

        (,, bool hasAirdrop,, address creator) = rainbowFactory.tokenFeeConfig(address(token));
        assertEq(creator, creator1);
        assertFalse(hasAirdrop);

        uint256 positionId = rainbowFactory.tokenPositionIds(address(token));
        assertTrue(positionId > 0);

        // Verify ownership has been renounced
        assertEq(token.owner(), address(0), "Token ownership should be renounced");

        // Verify no airdrop tokens in contract (since no merkle root)
        assertEq(token.balanceOf(address(token)), 0);

        vm.stopPrank();
    }

    function testLaunchTokenWithAirdrop() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Airdrop Token", "AIR", MERKLE_ROOT, INITIAL_SUPPLY);

        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Airdrop Token", "AIR", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, address(creator1));

        assertTrue(address(token) < address(weth), "Token address must be less than WETH");
        (,, bool hasAirdrop,, address creator) = rainbowFactory.tokenFeeConfig(address(token));
        assertTrue(hasAirdrop);
        assertEq(creator, creator1);

        // Check supply allocations
        uint16 airdropBps = getCreatorAndAirdropBps();
        uint256 expectedAirdropAmount = (INITIAL_SUPPLY * airdropBps) / 10_000;

        // Verify airdrop tokens are held by the token contract
        assertEq(token.balanceOf(address(token)), expectedAirdropAmount);

        // Verify total supply is fully minted at creation
        assertEq(token.totalSupply(), INITIAL_SUPPLY);

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
        (uint16 creatorLPFeeBps,,,,) = rainbowFactory.tokenFeeConfig(address(token));
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

        (,, bool hasAirdrop,, address creator) = rainbowFactory.tokenFeeConfig(address(token));
        assertEq(creator, creator1);
        assertFalse(hasAirdrop);

        uint256 positionId = rainbowFactory.tokenPositionIds(address(token));
        assertTrue(positionId > 0);

        // Verify ownership has been renounced
        assertEq(token.owner(), address(0), "Token ownership should be renounced");
        vm.stopPrank();
    }

    function testCollectAndClaimFees() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Fee Token", "FEE", MERKLE_ROOT, INITIAL_SUPPLY);

        // Launch token
        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Fee Token", "FEE", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, creator1);

        assertTrue(address(token) < address(weth), "Token address must be less than WETH");

        // Deal some ETH and perform swap
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        weth.deposit{ value: 50 ether }();

        weth.approve(address(permit2), type(uint256).max);
        IPermit2(permit2).approve(address(weth), address(universalRouter), uint160(1000 ether), uint48(block.timestamp + 3600));

        // Pool Key
        PoolKey memory poolKey;
        (poolKey.currency0, poolKey.currency1, poolKey.fee, poolKey.tickSpacing, poolKey.hooks) = rainbowFactory.tokenPoolKeys(address(token));

        // Prepare V4 swap through Universal Router
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes memory actions = abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: false, // WETH -> Token
                amountIn: uint128(10 ether),
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(poolKey.currency1, uint256(10 ether)); // WETH
        params[2] = abi.encode(poolKey.currency0, uint256(0)); // Token

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        universalRouter.execute(commands, inputs, block.timestamp + 300);
        vm.stopPrank();

        // Mine some blocks to ensure fees are accumulated
        vm.roll(block.number + 100);

        // Record balances before fee collection
        vm.startPrank(creator1);
        uint256 creatorToken0Before = address(token) < address(weth) ? token.balanceOf(creator1) : weth.balanceOf(creator1);
        uint256 creatorToken1Before = address(token) < address(weth) ? weth.balanceOf(creator1) : token.balanceOf(creator1);

        // Collect fees and claim creator fees
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

    // Test that getUnclaimedFees works correctly
    function testGetUnclaimedFees() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Fee Token", "FEE", MERKLE_ROOT, INITIAL_SUPPLY);

        // Launch token
        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Fee Token", "FEE", MERKLE_ROOT, INITIAL_SUPPLY, 200, salt, creator1);

        assertTrue(address(token) < address(weth), "Token address must be less than WETH");

        // Initially, unclaimed fees should be zero
        (uint256 creatorFee0, uint256 creatorFee1, uint256 protocolFee0, uint256 protocolFee1) = rainbowFactory.getUnclaimedFees(address(token));
        assertEq(creatorFee0, 0);
        assertEq(creatorFee1, 0);
        assertEq(protocolFee0, 0);
        assertEq(protocolFee1, 0);

        // Deal some ETH and perform swap to generate fees
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        weth.deposit{ value: 50 ether }();

        // Perform swap WETH -> Token to generate fees
        weth.approve(address(permit2), type(uint256).max);
        IPermit2(permit2).approve(address(weth), address(universalRouter), uint160(10 ether), uint48(block.timestamp + 3600));

        PoolKey memory poolKey;
        (poolKey.currency0, poolKey.currency1, poolKey.fee, poolKey.tickSpacing, poolKey.hooks) = rainbowFactory.tokenPoolKeys(address(token));

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes memory actions = abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: false, // WETH -> Token
                amountIn: uint128(10 ether),
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(poolKey.currency1, uint256(10 ether)); // WETH
        params[2] = abi.encode(poolKey.currency0, uint256(0)); // Token

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        universalRouter.execute(commands, inputs, block.timestamp + 300);
        vm.stopPrank();

        // Mine some blocks to ensure fees are accumulated
        vm.roll(block.number + 100);

        // Now check unclaimed fees - they should still be zero until collected
        (creatorFee0, creatorFee1, protocolFee0, protocolFee1) = rainbowFactory.getUnclaimedFees(address(token));
        assertEq(creatorFee0, 0);
        assertEq(creatorFee1, 0);
        assertEq(protocolFee0, 0);
        assertEq(protocolFee1, 0);

        // Claim fees which internally calls collectFees
        vm.startPrank(creator1);
        rainbowFactory.claimCreatorFees(address(token), creator1);
        vm.stopPrank();

        // After claiming creator fees, protocol fees should still be visible
        (creatorFee0, creatorFee1, protocolFee0, protocolFee1) = rainbowFactory.getUnclaimedFees(address(token));
        assertEq(creatorFee0, 0); // Creator fees were claimed
        assertEq(creatorFee1, 0);
        assertTrue(protocolFee0 > 0 || protocolFee1 > 0, "Protocol should have unclaimed fees");

        // Claim protocol fees
        vm.startPrank(owner);
        rainbowFactory.claimProtocolFees(address(token), owner);
        vm.stopPrank();

        // All fees should now be zero
        (creatorFee0, creatorFee1, protocolFee0, protocolFee1) = rainbowFactory.getUnclaimedFees(address(token));
        assertEq(creatorFee0, 0);
        assertEq(creatorFee1, 0);
        assertEq(protocolFee0, 0);
        assertEq(protocolFee1, 0);
    }

    // Test that getUnclaimedFees reverts if the token is invalid
    function testGetUnclaimedFeesInvalidToken() public {
        // Test with a token that wasn't created by this factory
        vm.expectRevert(RainbowSuperTokenFactory.InvalidToken.selector);
        rainbowFactory.getUnclaimedFees(address(0x1234));
    }

    // Helper function to get creator and airdrop basis points
    function getCreatorAndAirdropBps() internal view returns (uint16) {
        (, uint16 airdropBps,,,) = rainbowFactory.defaultFeeConfig();
        return (airdropBps);
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
        assertEq(usdc.allowance(address(rainbowFactory), address(positionManager)), type(uint256).max);
        vm.stopPrank();
    }

    function testDefaultFeeConfigUpdatesPairToken() public {
        // Deploy mock USDC
        MockERC20 usdc = new MockERC20("USD Coin", "USDC");

        vm.startPrank(owner);

        RainbowSuperTokenFactory.FeeConfig memory newConfig =
            RainbowSuperTokenFactory.FeeConfig({ creatorLPFeeBps: 1500, airdropBps: 20, hasAirdrop: false, feeToken: address(usdc), creator: address(0) });

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

        // Setup user1 with USDC for swapping
        vm.stopPrank();
        vm.startPrank(address(usdc));
        usdc.mint(user1, 1000e18);
        vm.stopPrank();

        vm.startPrank(user1);
        usdc.approve(address(permit2), type(uint256).max);
        IPermit2(permit2).approve(address(usdc), address(universalRouter), uint160(1000 ether), uint48(block.timestamp + 3600));

        // Get pool key from factory
        PoolKey memory poolKey;
        (poolKey.currency0, poolKey.currency1, poolKey.fee, poolKey.tickSpacing, poolKey.hooks) = rainbowFactory.tokenPoolKeys(address(token));

        // Prepare V4 swap through Universal Router
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes memory actions = abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: false, // WETH -> Token
                amountIn: uint128(10 ether),
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(poolKey.currency1, uint256(10 ether)); // WETH
        params[2] = abi.encode(poolKey.currency0, uint256(0)); // Token

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        universalRouter.execute(commands, inputs, block.timestamp + 300);
        vm.stopPrank();

        // Mine some blocks
        vm.roll(block.number + 100);

        // Record balances before fee collection
        vm.startPrank(creator1);
        uint256 creatorToken0Before = token.balanceOf(creator1);
        uint256 creatorToken1Before = usdc.balanceOf(creator1);

        // Collect fees and claim creator fees
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

    function testChangePot() public {
        vm.startPrank(user2);
        vm.expectRevert("UNAUTHORIZED");
        rainbowFactory.setPot(user1);
        vm.stopPrank();

        vm.prank(owner);
        rainbowFactory.setPot(user2);

        assertEq(address(rainbowFactory.overTheRainbowPot()), user2);
    }

    function testOwnershipRenouncedPreventsMiniting() public {
        vm.startPrank(creator1);

        (bytes32 salt,) = findValidSalt(creator1, "Test Token", "TEST", bytes32(0), INITIAL_SUPPLY);

        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Test Token", "TEST", bytes32(0), INITIAL_SUPPLY, 200, salt, address(creator1));

        // Verify ownership has been renounced
        assertEq(token.owner(), address(0), "Token ownership should be renounced");

        // Try to mint as anyone - should fail since owner is address(0)
        vm.expectRevert("UNAUTHORIZED");
        token.mint(user1, 1000e18);
        vm.stopPrank();

        // Try to mint as the factory - should also fail
        vm.prank(address(rainbowFactory));
        vm.expectRevert("UNAUTHORIZED");
        token.mint(user1, 1000e18);

        // Try to mint as the original creator - should also fail
        vm.prank(creator1);
        vm.expectRevert("UNAUTHORIZED");
        token.mint(user1, 1000e18);

        // Verify no one can claim ownership back
        vm.expectRevert("UNAUTHORIZED");
        token.transferOwnership(creator1);
    }

    function testClaimsWorkAfterOwnershipRenounced() public {
        vm.startPrank(creator1);

        // Get airdrop allocation amount first to set realistic claim amounts
        uint16 airdropBps = getCreatorAndAirdropBps();
        uint256 expectedAirdropAmount = (INITIAL_SUPPLY * airdropBps) / 10_000;

        // Create merkle tree for airdrop claims with realistic amounts
        // Each user can claim 1/4 of the airdrop allocation
        uint256 claimAmount = expectedAirdropAmount / 4;
        bytes32[] memory data = new bytes32[](4);
        data[1] = bytes32(keccak256(bytes.concat(keccak256(abi.encode(user1, claimAmount)))));
        data[2] = bytes32(keccak256(bytes.concat(keccak256(abi.encode(user2, claimAmount)))));
        data[3] = bytes32(keccak256(bytes.concat(keccak256(abi.encode(vm.addr(3), claimAmount)))));

        Merkle tempMerkle = new Merkle();
        bytes32 merkleRoot = tempMerkle.getRoot(data);

        (bytes32 salt,) = findValidSalt(creator1, "Claim Test", "CLAIM", merkleRoot, INITIAL_SUPPLY);

        // Launch token with airdrop via factory (auto-renounces ownership)
        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Claim Test", "CLAIM", merkleRoot, INITIAL_SUPPLY, 200, salt, address(creator1));

        // Verify ownership is renounced
        assertEq(token.owner(), address(0), "Ownership should be renounced");

        // Verify airdrop tokens are in the contract
        assertEq(token.balanceOf(address(token)), expectedAirdropAmount, "Contract should hold airdrop tokens");

        vm.stopPrank();

        // User 1 claims successfully
        bytes32[] memory proof1 = tempMerkle.getProof(data, 1);
        vm.prank(user1);
        token.claim(proof1, user1, claimAmount);
        assertEq(token.balanceOf(user1), claimAmount, "User1 should receive tokens");

        // User 2 claims successfully
        bytes32[] memory proof2 = tempMerkle.getProof(data, 2);
        vm.prank(user2);
        token.claim(proof2, user2, claimAmount);
        assertEq(token.balanceOf(user2), claimAmount, "User2 should receive tokens");

        // Verify claims work correctly despite no owner
        uint256 remainingBalance = token.balanceOf(address(token));
        assertEq(remainingBalance, expectedAirdropAmount - (claimAmount * 2), "Contract balance should decrease correctly");
        assertTrue(remainingBalance < expectedAirdropAmount, "Contract balance should decrease after claims");
    }

    function testFixedSupplyAfterCreation() public {
        vm.startPrank(creator1);

        // Launch token via factory with specific allocations
        bytes32 merkleRoot = keccak256("test merkle");
        (bytes32 salt,) = findValidSalt(creator1, "Fixed Supply", "FIXED", merkleRoot, INITIAL_SUPPLY);

        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken("Fixed Supply", "FIXED", merkleRoot, INITIAL_SUPPLY, 200, salt, address(creator1));

        // Get all allocation amounts
        (, uint16 airdropBps,,,) = rainbowFactory.defaultFeeConfig();

        // Calculate expected allocations
        uint256 expectedAirdropAmount = (INITIAL_SUPPLY * airdropBps) / 10_000;
        uint256 expectedLpAmount = INITIAL_SUPPLY - expectedAirdropAmount;

        // Verify total supply equals expected amount
        assertEq(token.totalSupply(), INITIAL_SUPPLY, "Total supply should equal initial supply");

        // Verify all allocations sum correctly
        uint256 creatorBalance = token.balanceOf(creator1);
        uint256 protocolBalance = token.balanceOf(pot);
        uint256 airdropBalance = token.balanceOf(address(token));
        uint256 lpBalance = token.balanceOf(address(rainbowFactory)); // LP tokens held by factory initially

        // Note: LP tokens are transferred to Uniswap position, so we check position instead
        uint256 positionId = rainbowFactory.tokenPositionIds(address(token));
        assertTrue(positionId > 0, "Position should exist");

        // Verify allocations (creator, protocol, airdrop)
        assertEq(airdropBalance, expectedAirdropAmount, "Airdrop allocation incorrect");

        // Verify no additional minting is possible (owner is address(0))
        vm.expectRevert("UNAUTHORIZED");
        token.mint(user1, 1e18);

        vm.stopPrank();

        // Even the factory cannot mint more
        vm.prank(address(rainbowFactory));
        vm.expectRevert("UNAUTHORIZED");
        token.mint(user1, 1e18);

        // Verify total supply remains constant
        assertEq(token.totalSupply(), INITIAL_SUPPLY, "Total supply should not change");
    }

    function testPoolManagerBalanceWithoutAirdrop() public {
        vm.startPrank(creator1);

        // Launch token WITHOUT airdrop (merkleroot = bytes32(0))
        (bytes32 salt,) = findValidSalt(creator1, "Balance Test", "BALT", bytes32(0), INITIAL_SUPPLY);
        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken(
            "Balance Test",
            "BALT",
            bytes32(0), // No merkleroot = no airdrop
            INITIAL_SUPPLY,
            200,
            salt,
            address(creator1)
        );

        // Key insight: When merkleroot is bytes32(0), hasAirdrop = false
        // This means NO airdrop allocation happens, regardless of airdropBps in config
        // Therefore, ALL tokens go to LP and end up in PoolManager

        uint256 poolManagerBalance = token.balanceOf(address(poolManager));

        // The original test incorrectly expected LP supply to be reduced by airdropBps
        // But when hasAirdrop = false, airdropAmount = 0, so lpSupply = totalSupply
        assertEq(poolManagerBalance, INITIAL_SUPPLY, "PoolManager holds full supply when no airdrop");

        // Verify no tokens were minted to the token contract for airdrop
        uint256 tokenContractBalance = token.balanceOf(address(token));
        assertEq(tokenContractBalance, 0, "No airdrop tokens when merkleroot is zero");

        // Verify the position was created
        uint256 positionTokenId = rainbowFactory.tokenPositionIds(address(token));
        assertTrue(positionTokenId > 0, "Position should have been created");

        vm.stopPrank();
    }

    function testPoolManagerBalanceWithAirdrop() public {
        vm.startPrank(creator1);

        // Launch token WITH airdrop (non-zero merkleroot)
        bytes32 merkleroot = bytes32(uint256(1)); // Non-zero merkleroot
        (bytes32 salt,) = findValidSalt(creator1, "Airdrop Test", "AIRT", merkleroot, INITIAL_SUPPLY);
        RainbowSuperToken token = rainbowFactory.launchRainbowSuperToken(
            "Airdrop Test",
            "AIRT",
            merkleroot, // Non-zero merkleroot = has airdrop
            INITIAL_SUPPLY,
            200,
            salt,
            address(creator1)
        );

        // With airdrop enabled, tokens are split between LP and airdrop
        (, uint16 airdropBps,,,) = rainbowFactory.defaultFeeConfig();
        uint256 airdropAmount = (INITIAL_SUPPLY * airdropBps) / 10_000;
        uint256 lpSupply = INITIAL_SUPPLY - airdropAmount;

        // PoolManager should only have the LP supply
        uint256 poolManagerBalance = token.balanceOf(address(poolManager));
        assertEq(poolManagerBalance, lpSupply, "PoolManager holds LP supply when airdrop enabled");

        // Token contract should hold the airdrop amount
        uint256 tokenContractBalance = token.balanceOf(address(token));
        assertEq(tokenContractBalance, airdropAmount, "Token contract holds airdrop amount");

        // Total should equal initial supply
        assertEq(poolManagerBalance + tokenContractBalance, INITIAL_SUPPLY, "Total supply accounted for");

        vm.stopPrank();
    }
}
