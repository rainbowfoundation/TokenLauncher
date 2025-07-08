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

    function setUp() public override {
        super.setUp();

        uint256 amount = 100e18;

        merkle = new Merkle();
        _data = new bytes32[](200);
        address[] memory recipients = new address[](200);
        uint256[] memory amounts = new uint256[](200);
        for (uint256 i = 1; i < 200; i++) {
            recipients[i - 1] = vm.addr(i);
            _data[i] = bytes32(keccak256(bytes.concat(keccak256(abi.encode(vm.addr(i), amount)))));
            amounts[i - 1] = amount;
        }
        root = merkle.getRoot(_data);

        uint256 id;
        assembly {
            id := chainid()
        }

        token = new RainbowSuperToken("Test Token", "TEST", "https://rainbow.me/testMetadata", root, amount * 100, id);

        // Mint the airdrop allocation to the token contract itself
        token.mint(address(token), amount * 100);
    }

    function testClaim() public {
        uint256 amount = 100e18;
        address recipient = vm.addr(1);
        bytes32[] memory proof = merkle.getProof(_data, 1);

        uint256 initialBalance = token.balanceOf(recipient);

        vm.startPrank(vm.addr(1));
        token.claim(proof, recipient, amount);

        assertEq(token.balanceOf(recipient), initialBalance + amount);

        // Verify contract balance decreased
        assertEq(token.balanceOf(address(token)), amount * 99);

        vm.expectRevert(RainbowSuperToken.AlreadyClaimed.selector);
        token.claim(proof, recipient, amount);
        vm.stopPrank();

        for (uint256 i = 2; i < 101; i++) {
            proof = merkle.getProof(_data, i);
            address _user = vm.addr(i);

            uint256 _initialBalance = token.balanceOf(_user);
            vm.prank(_user);
            token.claim(proof, _user, amount);

            assertEq(token.balanceOf(_user), _initialBalance + amount);
        }

        // After claiming 100 tokens, contract should have no tokens left
        assertEq(token.balanceOf(address(token)), 0);

        // No tokens after we've claimed all of the alloted supply
        address user = vm.addr(106);
        proof = merkle.getProof(_data, 106);

        initialBalance = token.balanceOf(user);
        vm.startPrank(user);
        vm.expectRevert(RainbowSuperToken.CannotClaimZero.selector);
        token.claim(proof, user, amount);
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
        // Bound the amount to prevent overflow
        amount = bound(amount, 0, type(uint256).max / 2);

        vm.expectRevert(RainbowSuperToken.Unauthorized.selector);
        token.crosschainMint(address(this), amount);

        uint256 initialBalance = token.balanceOf(address(this));

        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        token.crosschainMint(address(this), amount);

        assertEq(token.balanceOf(address(this)), initialBalance + amount);
    }

    function testOnlySuperchainBridgeCanBurn(uint256 amount) public {
        // Bound the amount to prevent overflow
        amount = bound(amount, 0, type(uint256).max / 2);

        // Since this test creates its own token (not via factory), it still has ownership
        token.mint(address(this), amount);

        vm.expectRevert(RainbowSuperToken.Unauthorized.selector);
        token.crosschainBurn(address(this), amount);

        uint256 initialBalance = token.balanceOf(address(this));

        vm.prank(SUPERCHAIN_TOKEN_BRIDGE);
        token.crosschainBurn(address(this), amount);

        assertEq(token.balanceOf(address(this)), initialBalance - amount);
    }

    function testTokenMetaData() public {
        uint256 amount = 100e18;
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);

        token = new RainbowSuperToken("Test Token", "TEST", "https://rainbow.me/testMetadata", root, amount * 100, 1);
        assertEq(token.tokenURI(), "https://rainbow.me/testMetadata");
    }

    function testTokenSupportsInterfaces() public view {
        assertTrue(token.supportsInterface(0x33331994)); // ERC7802 Interface ID
        assertTrue(token.supportsInterface(0x36372b07)); // ERC20 Interface ID
        assertTrue(token.supportsInterface(0x01ffc9a7)); // ERC165 Interface ID

        assertFalse(token.supportsInterface(0x00000000)); // Invalid Interface ID
        assertFalse(token.supportsInterface(0xffffffff)); // Invalid Interface ID
    }

    function testClaimAmountCappedToContractBalance() public {
        // Create a new merkle tree with a user eligible for 200 tokens
        uint256 largeAmount = 200e18;
        uint256 contractBalance = 50e18;

        // Setup merkle tree for one user with large allocation
        bytes32[] memory data = new bytes32[](2);
        data[1] = bytes32(keccak256(bytes.concat(keccak256(abi.encode(user1, largeAmount)))));

        Merkle tempMerkle = new Merkle();
        bytes32 tempRoot = tempMerkle.getRoot(data);

        uint256 id;
        assembly {
            id := chainid()
        }

        // Create token with the new merkle root
        RainbowSuperToken cappedToken = new RainbowSuperToken(
            "Capped Token",
            "CAP",
            "https://rainbow.me/testMetadata",
            tempRoot,
            contractBalance, // airdrop allocation matches what we'll mint
            id
        );

        // Mint only 50 tokens to the contract (less than user's 200 token allocation)
        cappedToken.mint(address(cappedToken), contractBalance);

        // Get proof for user1
        bytes32[] memory proof = tempMerkle.getProof(data, 1);

        // User claims their allocation
        vm.prank(user1);
        cappedToken.claim(proof, user1, largeAmount);

        // Verify user received only the contract balance, not their full allocation
        assertEq(cappedToken.balanceOf(user1), contractBalance, "User should receive capped amount");
        assertEq(cappedToken.balanceOf(address(cappedToken)), 0, "Contract should have no tokens left");
    }

    function testPartialClaimWhenInsufficientBalance() public {
        // Setup: 3 users each eligible for 100 tokens
        uint256 claimAmount = 100e18;
        uint256 totalContractBalance = 150e18; // Only enough for 1.5 users

        // Create merkle tree with 3 users
        bytes32[] memory data = new bytes32[](4);
        data[1] = bytes32(keccak256(bytes.concat(keccak256(abi.encode(user1, claimAmount)))));
        data[2] = bytes32(keccak256(bytes.concat(keccak256(abi.encode(user2, claimAmount)))));
        data[3] = bytes32(keccak256(bytes.concat(keccak256(abi.encode(vm.addr(3), claimAmount)))));

        Merkle tempMerkle = new Merkle();
        bytes32 tempRoot = tempMerkle.getRoot(data);

        uint256 id;
        assembly {
            id := chainid()
        }

        // Create token with limited supply
        RainbowSuperToken partialToken = new RainbowSuperToken("Partial Token", "PART", "https://rainbow.me/testMetadata", tempRoot, totalContractBalance, id);

        // Mint only 150 tokens (less than 300 total eligible)
        partialToken.mint(address(partialToken), totalContractBalance);

        // User 1 claims full amount
        bytes32[] memory proof1 = tempMerkle.getProof(data, 1);
        vm.prank(user1);
        partialToken.claim(proof1, user1, claimAmount);
        assertEq(partialToken.balanceOf(user1), claimAmount, "User1 should get full amount");

        // User 2 claims partial amount (only 50 left)
        bytes32[] memory proof2 = tempMerkle.getProof(data, 2);
        vm.prank(user2);
        partialToken.claim(proof2, user2, claimAmount);
        assertEq(partialToken.balanceOf(user2), 50e18, "User2 should get partial amount");

        // User 3 gets nothing
        bytes32[] memory proof3 = tempMerkle.getProof(data, 3);
        vm.prank(vm.addr(3));
        vm.expectRevert(RainbowSuperToken.CannotClaimZero.selector);
        partialToken.claim(proof3, vm.addr(3), claimAmount);

        // Verify contract is empty
        assertEq(partialToken.balanceOf(address(partialToken)), 0, "Contract should be empty");
    }
}
