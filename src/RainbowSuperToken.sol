// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contracts
import { Owned } from "lib/solmate/src/auth/Owned.sol";
import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";

import { MerkleProofLib } from "lib/solady/src/utils/MerkleProofLib.sol";

/// @title RainbowSuperToken
/// @author CopyPaste - for Rainbow with love <3
/// @notice An implementation of ERC20 extending with IERC7802 to allow for unified use across the
///     Superchain.
contract RainbowSuperToken is ERC20, Owned {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a crosschain transfer mints tokens.
    /// @param to       Address of the account tokens are being minted for.
    /// @param amount   Amount of tokens minted.
    /// @param sender   Address of the account that finilized the crosschain transfer.
    event CrosschainMint(address indexed to, uint256 amount, address indexed sender);

    /// @notice Emitted when a crosschain transfer burns tokens.
    /// @param from     Address of the account tokens are being burned from.
    /// @param amount   Amount of tokens burned.
    /// @param sender   Address of the account that initiated the crosschain transfer.
    event CrosschainBurn(address indexed from, uint256 amount, address indexed sender);

    /// @notice Emitted when tokens are claimed
    /// @param to The address that claimed the tokens
    /// @param amount The amount of tokens claimed
    event Claim(address indexed to, uint256 amount);
    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /// @dev The merkle root to be used for claims

    bytes32 public merkleRoot;

    /// @dev The maximum total supply of the token that can be minted
    uint256 public maxTotalMintedSupply;

    /// @dev Original Chain the token was deployed on
    uint256 public originalChainId;

    /// @param name The name of the token
    /// @param symbol The symbol of the token
    /// @param _tokenURI A Url pointing to the metadata for the token
    /// @param _merkleRoot The merkle root to be used for claims
    /// @param _maxTotalMintedSupply The maximum total supply of the token that can be minted
    constructor(
        string memory name,
        string memory symbol,
        string memory _tokenURI,
        bytes32 _merkleRoot,
        uint256 _maxTotalMintedSupply,
        uint256 _originalChainId
    )
        ERC20(name, symbol, 18)
        Owned(msg.sender)
    {
        tokenURI = _tokenURI;
        merkleRoot = _merkleRoot;
        maxTotalMintedSupply = _maxTotalMintedSupply;
        originalChainId = _originalChainId;
    }

    modifier onlyOriginalChain() {
        uint256 id;
        assembly {
            id := chainid()
        }
        if (id != originalChainId) revert Unauthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                MINTING
    //////////////////////////////////////////////////////////////*/

    /// @dev Tracks the number of tokens we have minted in claims so far
    uint256 public totalMintedSupply;

    /// @dev Tracks if a user has claimed their tokens
    mapping(address => bool) public claimed;

    /// @dev Error emitted when the proof supplied is invalid
    error InvalidProof();

    /// @dev Error emitted when a user has already claimed their tokens
    error AlreadyClaimed();

    /// @dev Error emitted when a user tries to claim 0 tokens
    error CannotClaimZero();

    /// @param proof The merkle proof to verify the claim
    /// @param recipient The address to mint the tokens to
    /// @param amount The amount of tokens to mint
    function claim(bytes32[] calldata proof, address recipient, uint256 amount) external onlyOriginalChain {
        if (claimed[recipient]) revert AlreadyClaimed();

        claimed[recipient] = true;

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(recipient, amount))));
        if (!MerkleProofLib.verifyCalldata(proof, merkleRoot, leaf)) {
            revert InvalidProof();
        }

        if (amount + totalMintedSupply > maxTotalMintedSupply) {
            amount = maxTotalMintedSupply - totalMintedSupply;
        }

        if (amount == 0) {
            revert CannotClaimZero();
        }

        totalMintedSupply += amount;
        totalSupply += amount;

        // Mint the points to the recipient
        unchecked {
            balanceOf[recipient] += amount;
        }

        emit Transfer(address(0), recipient, amount);
        emit Claim(recipient, amount);
    }

    /// @param recipient The address to mint the tokens to
    /// @param amount The amount of tokens to mint
    function mint(address recipient, uint256 amount) external onlyOriginalChain onlyOwner {
        _mint(recipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            RAINBOW METADATA
    //////////////////////////////////////////////////////////////*/

    /// @dev tokenURI The URI for the token metadata.
    string public tokenURI;

    /*//////////////////////////////////////////////////////////////
                          SUPERCHAIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Error emitted for unauthorized access.
    error Unauthorized();

    /// @dev The precompile for the superchain token bridge.
    address internal constant SUPERCHAIN_TOKEN_BRIDGE = 0x4200000000000000000000000000000000000028;

    /// i@notice Allows the SuperchainTokenBridge to mint tokens.
    /// @param _to     Address to mint tokens to.
    /// @param _amount Amount of tokens to mint.
    function crosschainMint(address _to, uint256 _amount) external {
        if (msg.sender != SUPERCHAIN_TOKEN_BRIDGE) revert Unauthorized();

        _mint(_to, _amount);

        emit CrosschainMint(_to, _amount, msg.sender);
    }

    /// @notice Allows the SuperchainTokenBridge to burn tokens.
    /// @param _from   Address to burn tokens from.
    /// @param _amount Amount of tokens to burn.
    function crosschainBurn(address _from, uint256 _amount) external {
        if (msg.sender != SUPERCHAIN_TOKEN_BRIDGE) revert Unauthorized();

        _burn(_from, _amount);

        emit CrosschainBurn(_from, _amount, msg.sender);
    }

    /// @dev ERC165 Interface Id Compatibility check
    /// @param _interfaceId Interface ID to check for support.
    /// @return True if the contract supports the given interface ID.
    function supportsInterface(bytes4 _interfaceId) public pure returns (bool) {
        return _interfaceId == 0x33331994 // ERC7802 Interface ID
            || _interfaceId == 0x36372b07 // ERC20 Interface ID
            || _interfaceId == 0x01ffc9a7; // ERC165 Interface ID
    }
}
