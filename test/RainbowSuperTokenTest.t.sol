// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./BaseRainbowTest.t.sol";
import { Merkle } from "lib/murky/src/Merkle.sol";
import { RainbowSuperToken } from "../src/RainbowSuperToken.sol";

contract RainbowSuperTokenFactoryTest is BaseRainbowTest {

    RainbowSuperToken public token;

    bytes32 public root;
    Merkle public merkle;
    bytes32[] public _data;

    function setUp() override public {
        super.setUp();

        uint256 amount = 100e18;

        merkle = new Merkle();
        _data = new bytes32[](100);
        address[] memory recipients = new address[](100);
        uint256[] memory amounts = new uint256[](100);
        for (uint256 i = 1; i < 100; i++) {
            recipients[i - 1] = vm.addr(i);
            _data[i] = bytes32(keccak256(bytes.concat(keccak256(abi.encode(vm.addr(i), amount)))));
            amounts[i - 1] = amount;
        }
        root = merkle.getRoot(_data);

        // Set up default metadata for tests
        defaultMetadata = RainbowSuperToken.RainbowTokenMetadata({
            tokenURI: "ipfs://test",
            description: "Test Token",
            farcasterProfileUrl: "https://warpcast.com/test",
            farcasterChannelUrl: "https://warpcast.com/~/channel/test",
            telegramUrl: "https://t.me/test"
        });

        token = new RainbowSuperToken("Test Token", "TEST", defaultMetadata, root, 1_000 ether);
    }

    function testClaim() public {
        uint256 amount = 100e18;
        address recipient = vm.addr(1);
        bytes32[] memory proof = merkle.getProof(_data, 1);

        uint256 initialBalance = token.balanceOf(recipient);

        vm.startPrank(vm.addr(1));
        token.claim(proof, recipient, amount);

        assertEq(token.balanceOf(recipient), initialBalance + amount);

        vm.expectRevert(RainbowSuperToken.AlreadyClaimed.selector);
        token.claim(proof, recipient, amount);
        vm.stopPrank();

        for (uint256 i = 1; i < 100; i++) {
            proof = merkle.getProof(_data, i);
            
            if (token.maxTotalMintedSupply() < token.totalSupply() + amount) {
                vm.startPrank(vm.addr(i));
                vm.expectRevert();
                token.claim(proof, vm.addr(i), amount);

                return;
            }
        }
    }

    function testCannotUseAFalseClaim() public {
        uint256 amount = 100e18;
        address recipient = vm.addr(1);
        bytes32[] memory proof = merkle.getProof(_data, 2);

        vm.expectRevert(RainbowSuperToken.InvalidProof.selector);
        token.claim(proof, recipient, amount);
    }

    
    address internal constant SUPERCHAIN_TOKEN_BRIDGE = 0x4200000000000000000000000000000000000028;

    function testOnlySuperchainBridgeCanMint(uint256 amount) public {
        vm.expectRevert(RainbowSuperToken.Unauthorized.selector);
        token.crosschainMint(address(this), amount);

        uint256 initialBalance = token.balanceOf(address(this));

        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        token.crosschainMint(address(this), amount);

        assertEq(token.balanceOf(address(this)), initialBalance + amount);
    }

    function testOnlySuperchainBridgeCanBurn(uint256 amount) public {
        token.mint(address(this), amount);

        vm.expectRevert(RainbowSuperToken.Unauthorized.selector);
        token.crosschainBurn(address(this), amount);

        uint256 initialBalance = token.balanceOf(address(this));

        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        token.crosschainBurn(address(this), amount);

        assertEq(token.balanceOf(address(this)), initialBalance - amount);
    }

    function testTokenMetaData() view public {
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);

        assertEq(token.tokenURI(), "ipfs://test");
        assertEq(token.description(), "Test Token");
        assertEq(token.farcasterProfileUrl(), "https://warpcast.com/test");
        assertEq(token.farcasterChannelUrl(), "https://warpcast.com/~/channel/test");
        assertEq(token.telegramUrl(), "https://t.me/test");
    }

    function testTokenSupportsInterfaces() view public {
        assertTrue(token.supportsInterface(0x33331994)); // ERC7802 Interface ID
        assertTrue(token.supportsInterface(0x36372b07)); // ERC20 Interface ID
        assertTrue(token.supportsInterface(0x01ffc9a7)); // ERC165 Interface ID

        assertFalse(token.supportsInterface(0x00000000)); // Invalid Interface ID
        assertFalse(token.supportsInterface(0xffffffff)); // Invalid Interface ID
    }
}
