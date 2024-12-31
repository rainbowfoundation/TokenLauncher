// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./BaseRainbowTest.t.sol";
import { RainbowSuperToken } from "../src/RainbowSuperToken.sol";

contract RainbowSuperTokenFactoryTest is BaseRainbowTest {
    bytes32 public constant MERKLE_ROOT = keccak256("test");

    function setUp() public override {
        super.setUp();

        // Set up default metadata for tests
        defaultMetadata = RainbowSuperToken.RainbowTokenMetadata({
            tokenURI: "ipfs://test",
            description: "Test Token",
            farcasterProfileUrl: "https://warpcast.com/test",
            farcasterChannelUrl: "https://warpcast.com/~/channel/test",
            telegramUrl: "https://t.me/test"
        });
    }

    function testLaunchToken() public {
        vm.startPrank(creator1);

        RainbowSuperToken token =
            rainbowFactory.launchRainbowSuperToken("Test Token", "TEST", MERKLE_ROOT, INITIAL_SUPPLY, 200, bytes32(0), false, address(this), defaultMetadata);

        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.totalSupply(), INITIAL_SUPPLY);

        // Get individual fee config components
        (uint16 creatorLPFeeBps, uint16 protocolBaseBps, uint16 creatorBaseBps, uint16 airdropBps, bool hasAirdrop, address creator) =
            rainbowFactory.tokenFeeConfig(address(token));

        assertEq(creator, creator1);
        assertFalse(hasAirdrop);

        // Verify position was created
        uint256 positionId = rainbowFactory.tokenPositionIds(address(token));
        assertTrue(positionId > 0);
    }
}
