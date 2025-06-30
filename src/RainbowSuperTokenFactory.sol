// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Owned } from "lib/solmate/src/auth/Owned.sol";
import { ERC721TokenReceiver } from "solmate/tokens/ERC721.sol";
import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";
import { SafeTransferLib } from "lib/solmate/src/utils/SafeTransferLib.sol";

import { RainbowSuperToken } from "src/RainbowSuperToken.sol";

import { TickMath } from "vendor/v3-core/libraries/TickMath.sol";
import { FixedPointMathLib } from "lib/solmate/src/utils/FixedPointMathLib.sol";

import { ISwapRouter02 } from "vendor/swap-router/interfaces/ISwapRouter02.sol";

import { IWETH9 } from "vendor/v3-periphery/interfaces/external/IWETH9.sol";
import { IUniswapV3Pool } from "vendor/v3-core/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "vendor/v3-core/interfaces/IUniswapV3Factory.sol";
import { INonfungiblePositionManager } from "vendor/v3-periphery/interfaces/INonfungiblePositionManager.sol";

/// @title RainbowSuperTokenFactory
/// @author CopyPaste - for Rainbow with love <3
/// @notice A factory contract for creating RainbowSuperTokens and managing their liquidity positions.
/// @notice Protocol fees are allocated to be sent 🌈 Over the Rainbow 🌈
contract RainbowSuperTokenFactory is Owned, ERC721TokenReceiver {
    using TickMath for int24;
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ReservedName();
    error ReservedTicker();
    error ZeroSupply();
    error BannedName();
    error BannedTicker();
    error NotUniswapPositionManager();
    error InvalidFeeSplit();
    error InvalidSupplyAllocation();
    error NoFeesToClaim();
    error Unauthorized();
    error IncorrectSalt();
    error InsufficientFunds();
    error InvalidToken();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @param pot The address of the new Over the Rainbow Pot
    event NewPot(address indexed pot);

    /// @param recipient The address of the recipient
    /// @param token The token address to claim initial fees for
    /// @param amount The amount of tokens claimed
    event OverTheRainbowClaimed(address indexed recipient, address indexed token, uint256 amount);

    /// @param token The address of the newly created token
    /// @param owner The address of the creator of the token
    /// @param creator The address of the creator of the token
    event RainbowSuperTokenCreated(address indexed token, address indexed owner, address indexed creator, string uri);

    /// @param token The address of the token
    /// @param config The new fee configuration
    event FeeConfigUpdated(address indexed token, FeeConfig config);

    /// @param tokenId The ID of the NFT Position
    /// @param creatorFee0 The amount of token0 fees for the creator
    /// @param creatorFee1 The amount of token1 fees for the creator
    /// @param protocolFee0 The amount of token0 fees for the protocol
    /// @param protocolFee1 The amount of token1 fees for the protocol
    event FeesCollected(uint256 indexed tokenId, uint256 creatorFee0, uint256 creatorFee1, uint256 protocolFee0, uint256 protocolFee1);

    /// @param recipient The address of the recipient
    /// @param tokenId The ID of the NFT Position
    /// @param amount0 The amount of token0 fees claimed
    /// @param amount1 The amount of token1 fees claimed
    event FeesClaimed(address indexed recipient, uint256 indexed tokenId, uint256 amount0, uint256 amount1);

    /// @param token The address of the new default pair token
    event NewDefaultPairToken(address indexed token);

    /*//////////////////////////////////////////////////////////////
                              FEE CONFIG
    //////////////////////////////////////////////////////////////*/

    struct FeeConfig {
        // Creator's share of LP fees (in basis points, max 10000)
        uint16 creatorLPFeeBps;
        // Airdrop allocation from initial supply (in basis points)
        uint16 airdropBps;
        // Whether this token has airdrop enabled
        bool hasAirdrop;
        // Fee Token
        address feeToken;
        // Creator address for this token
        address creator;
    }

    struct UnclaimedFees {
        uint128 unclaimed0;
        uint128 unclaimed1;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev The canonical Uniswap V3 factory contract
    IUniswapV3Factory public immutable uniswapV3Factory;

    /// @dev The canonical WETH token contract
    IWETH9 public immutable WETH;

    /// @dev The default pair token
    ERC20 public defaultPairToken;

    /// @dev The Nonfungible Position Manager contract
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @dev The Uniswap V3 SwapRouter contract
    ISwapRouter02 public immutable swapRouter;

    /// @dev The base URI for all tokens
    string public baseTokenURI;

    /// @dev The mapping of banned names
    mapping(string => bool) public bannedNames;

    /// @dev The mapping of banned tickers
    mapping(string => bool) public bannedTickers;

    /// @dev The mapping from token address to its fee configuration
    mapping(address => FeeConfig) public tokenFeeConfig;

    /// @dev The mapping from token address to its liquidity position ID
    mapping(address => uint256) public tokenPositionIds;

    /// @dev The mapping from tokenId to creator's unclaimed fees
    mapping(uint256 => UnclaimedFees) public creatorUnclaimedFees;

    /// @dev The mapping from tokenId to protocol's unclaimed fees
    mapping(uint256 => UnclaimedFees) public protocolUnclaimedFees;

    /// @dev 🌈
    address public overTheRainbowPot;

    /// @dev The Uniswap V3 Pool fee
    uint24 public POOL_FEE = 10_000;

    /// @dev The Uniswap V3 Tick spacing
    int24 public TICK_SPACING = 200;

    /// @dev Default fee configuration
    FeeConfig public defaultFeeConfig = FeeConfig({
        creatorLPFeeBps: 5000, // 50% of LP fees to creator (50% implicit Protocol LP fee)
        airdropBps: 50, // 0.50% to airdrop
        hasAirdrop: false,
        feeToken: address(WETH),
        creator: address(0)
    });

    bytes32 public constant RainbowSuperTokenContractCodeHash = keccak256(type(RainbowSuperToken).creationCode);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _uniswapV3Factory The address of the Uniswap V3 factory contract
    /// @param _nonfungiblePositionManager The address of the Uniswap V3 Nonfungible Position Manager contract
    /// @param _swapRouter The address of the Uniswap V3 SwapRouter contract
    /// @param _weth The address of the WETH contract
    /// @param _baseTokenURI The base URI for all tokens
    constructor(
        address _uniswapV3Factory,
        address _overTheRainbow,
        address _nonfungiblePositionManager,
        address _swapRouter,
        address _weth,
        string memory _baseTokenURI
    )
        Owned(msg.sender)
    {
        WETH = IWETH9(payable(_weth));
        swapRouter = ISwapRouter02(_swapRouter);
        uniswapV3Factory = IUniswapV3Factory(_uniswapV3Factory);
        nonfungiblePositionManager = INonfungiblePositionManager(_nonfungiblePositionManager);
        baseTokenURI = _baseTokenURI;
        overTheRainbowPot = _overTheRainbow;

        WETH.approve(_swapRouter, type(uint256).max);
        defaultPairToken = ERC20(_weth);
    }

    /*//////////////////////////////////////////////////////////////
                             ADMIN CONTROLS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the new base token URI
    function setBaseTokenURI(string memory newBaseTokenURI) external onlyOwner {
        baseTokenURI = newBaseTokenURI;
    }

    /// @notice Set the new default pair token for all pairs
    /// @notice Only applies to new tokens
    /// @param newPairToken The new pair token to set
    function setNewPairToken(ERC20 newPairToken) public onlyOwner {
        defaultPairToken = newPairToken;
        defaultPairToken.approve(address(swapRouter), type(uint256).max);

        emit NewDefaultPairToken(address(newPairToken));
    }

    /// @notice Sets a new default fee configuration for all tokens made
    /// @param newConfig The new fee configuration to set
    function setDefaultFeeConfig(FeeConfig calldata newConfig) external onlyOwner {
        if (newConfig.creatorLPFeeBps > 10_000) revert InvalidFeeSplit();
        if (newConfig.airdropBps > 10_000) {
            revert InvalidSupplyAllocation();
        }
        defaultFeeConfig = newConfig;

        // We use address(0) as a default stand in
        emit FeeConfigUpdated(address(0), newConfig);

        if (newConfig.feeToken != address(defaultPairToken)) {
            setNewPairToken(ERC20(newConfig.feeToken));
        }
    }

    /// @notice Ban a name from being used
    /// @param name The name to ban
    /// @param status The status to set
    function banName(string memory name, bool status) external onlyOwner {
        bannedNames[name] = status;
    }

    /// @notice Ban a ticker from being used
    /// @param ticker The ticker to ban
    /// @param status The status to set
    function banTicker(string memory ticker, bool status) external onlyOwner {
        bannedTickers[ticker] = status;
    }

    /// @notice Set the new pool fee and tick spacing
    /// @param newPoolFee The new pool fee to set
    function setNewTickSpacing(uint24 newPoolFee) external onlyOwner {
        POOL_FEE = newPoolFee;
        TICK_SPACING = uniswapV3Factory.feeAmountTickSpacing(newPoolFee);
    }

    /*//////////////////////////////////////////////////////////////
                         RAINBOW TOKEN LAUNCHER
    //////////////////////////////////////////////////////////////*/

    /// @notice Launch a new RainbowSuperToken and buy initial tokens
    /// @param name The name of the token
    /// @param symbol The symbol of the token
    /// @param merkleroot The merkle root for airdrop claims
    /// @param supply The total supply of the token
    /// @param initialTick The initial tick for the liquidity position
    /// @param salt The salt for the token deployment
    /// @param creator The address to grant the initial tokens to
    ///
    /// @return The newly created RainbowSuperToken
    function launchRainbowSuperTokenAndBuy(
        string memory name,
        string memory symbol,
        bytes32 merkleroot,
        uint256 supply,
        int24 initialTick,
        bytes32 salt,
        address creator,
        uint256 amountIn
    )
        external
        payable
        returns (RainbowSuperToken)
    {
        if (address(defaultPairToken) == address(WETH)) {
            if (msg.value != amountIn) revert InsufficientFunds();
            WETH.deposit{ value: msg.value }();
        } else {
            if (msg.value != 0) revert InsufficientFunds(); // No ether should be sent if not WETH
            defaultPairToken.safeTransferFrom(msg.sender, address(this), amountIn);
        }

        RainbowSuperToken token = launchRainbowSuperToken(name, symbol, merkleroot, supply, initialTick, salt, creator);

        ISwapRouter02.ExactInputSingleParams memory swapParamsToken = ISwapRouter02.ExactInputSingleParams({
            tokenIn: address(defaultPairToken), // The token we are exchanging from
            tokenOut: address(token), // The token we are exchanging to
            fee: POOL_FEE, // The pool fee
            recipient: creator, // The recipient address
            amountIn: amountIn, // The amount of tokens to swap
            amountOutMinimum: 0, // Minimum amount to receive
            sqrtPriceLimitX96: 0 // No price limit
         });

        swapRouter.exactInputSingle(swapParamsToken);

        return token;
    }

    /// @notice Launch a new RainbowSuperToken and buy initial tokens
    /// @param name The name of the token
    /// @param symbol The symbol of the token
    /// @param merkleroot The merkle root for airdrop claims
    /// @param supply The total supply of the token
    /// @param initialTick The initial tick for the liquidity position
    /// @param salt The salt for the token deployment
    /// @param creator The address to grant the initial tokens to
    ///
    /// @return newToken The newly created RainbowSuperToken
    function launchRainbowSuperToken(
        string memory name,
        string memory symbol,
        bytes32 merkleroot,
        uint256 supply,
        int24 initialTick,
        bytes32 salt,
        address creator
    )
        public
        returns (RainbowSuperToken newToken)
    {
        if (supply == 0) revert ZeroSupply();

        // Name and ticker checks
        if (keccak256(abi.encodePacked(name)) == keccak256(abi.encodePacked("Rainbow"))) {
            revert ReservedName();
        }
        if (keccak256(abi.encodePacked(symbol)) == keccak256(abi.encodePacked("RNBW"))) {
            revert ReservedTicker();
        }
        if (bannedNames[name]) revert BannedName();
        if (bannedTickers[symbol]) revert BannedTicker();

        bool hasAirdrop = merkleroot != bytes32(0);

        (uint256 lpSupply, uint256 airdropAmount) = calculateSupplyAllocation(supply, hasAirdrop);

        uint256 id;
        assembly {
            id := chainid()
        }

        string memory tokenURI = string(toHexString(keccak256(abi.encode(creator, salt, name, symbol, merkleroot, supply)), 32));

        // Create token
        newToken = new RainbowSuperToken{ salt: keccak256(abi.encode(creator, salt)) }(
            name, symbol, string.concat(baseTokenURI, tokenURI), merkleroot, airdropAmount, id
        );

        address _pairToken = address(defaultPairToken);

        if (address(newToken) > address(_pairToken)) {
            revert IncorrectSalt();
        }

        // Mint airdrop allocation to the token contract itself
        if (airdropAmount > 0) {
            newToken.mint(address(newToken), airdropAmount);
        }

        // Set up fee configuration
        FeeConfig memory config = FeeConfig({
            creatorLPFeeBps: defaultFeeConfig.creatorLPFeeBps,
            airdropBps: defaultFeeConfig.airdropBps,
            hasAirdrop: hasAirdrop,
            feeToken: address(defaultPairToken),
            creator: msg.sender
        });
        tokenFeeConfig[address(newToken)] = config;

        IUniswapV3Pool pool = IUniswapV3Pool(uniswapV3Factory.createPool(address(newToken), address(_pairToken), POOL_FEE));

        uint160 initialSqrtRatio = initialTick.getSqrtRatioAtTick();
        pool.initialize(initialSqrtRatio);

        newToken.mint(address(this), lpSupply);

        // Provide initial liquidity
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(newToken),
            token1: address(_pairToken),
            fee: POOL_FEE,
            tickLower: initialTick,
            tickUpper: maxUsableTick(TICK_SPACING),
            amount0Desired: lpSupply,
            amount1Desired: 0,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        newToken.approve(address(nonfungiblePositionManager), lpSupply);
        (uint256 tokenId,,,) = nonfungiblePositionManager.mint(params);

        // Store the position ID
        tokenPositionIds[address(newToken)] = tokenId;

        emit RainbowSuperTokenCreated(address(newToken), creator, msg.sender, tokenURI);

        // Renounce ownership to make the token immutable
        newToken.renounceOwnership();
    }

    /// @notice Launch a RainbowSuperToken at the same address as on the original chain
    /// @param name The name of the token
    /// @param symbol The symbol of the token
    /// @param merkleroot The merkle root for airdrop claims
    /// @param supply The total supply of the token
    /// @param salt The salt for the token deployment
    /// @param creator The address to grant the initial tokens to
    ///
    /// @return newToken The newly created RainbowSuperToken
    function launchFromOtherChain(
        string memory name,
        string memory symbol,
        bytes32 merkleroot,
        uint256 supply,
        bytes32 salt,
        address creator,
        uint256 originalChainId,
        uint256 airdropAmount
    )
        external
        returns (RainbowSuperToken newToken)
    {
        if (supply == 0) revert ZeroSupply();

        // Name and ticker checks
        if (keccak256(abi.encodePacked(name)) == keccak256(abi.encodePacked("Rainbow"))) {
            revert ReservedName();
        }
        if (keccak256(abi.encodePacked(symbol)) == keccak256(abi.encodePacked("RNBW"))) {
            revert ReservedTicker();
        }

        if (bannedNames[name]) revert BannedName();
        if (bannedTickers[symbol]) revert BannedTicker();
        uint256 id;
        assembly {
            id := chainid()
        }

        if (originalChainId == id) revert Unauthorized();
        if (msg.sender != creator) revert Unauthorized();

        string memory tokenURI = string(toHexString(keccak256(abi.encode(creator, salt, name, symbol, merkleroot, supply)), 32));

        newToken = new RainbowSuperToken{ salt: keccak256(abi.encode(creator, salt)) }(
            name, symbol, string.concat(baseTokenURI, tokenURI), merkleroot, airdropAmount, originalChainId
        );
    }

    /*//////////////////////////////////////////////////////////////
                            FEE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @param newPot Update the address for the Over the Rainbow Pot
    function setPot(address newPot) external onlyOwner {
        overTheRainbowPot = newPot;

        emit NewPot(newPot);
    }

    /// @notice Calculate the allocation of supply for LP, creator and airdrop
    /// @param totalSupply The total supply of the token
    /// @param hasAirdrop Whether the token has airdrop enabled
    ///
    /// @return lpAmount The amount of tokens allocated to LP
    /// @return airdropAmount The amount of tokens allocated to airdrop
    function calculateSupplyAllocation(
        uint256 totalSupply,
        bool hasAirdrop
    )
        internal
        view
        returns (uint256 lpAmount, uint256 airdropAmount)
    {
        if (hasAirdrop) {
            airdropAmount = (totalSupply * defaultFeeConfig.airdropBps) / 10_000;
        } else {
            airdropAmount = 0;
        }
        lpAmount = totalSupply - airdropAmount;
    }

    /// @notice Get the unclaimed fees for a token
    /// @param token The token address to get the unclaimed fees for
    ///
    /// @return creatorFee0 The unclaimed fees for the creator
    /// @return creatorFee1 The unclaimed fees for the creator
    /// @return protocolFee0 The unclaimed fees for the protocol
    /// @return protocolFee1 The unclaimed fees for the protocol
    function getUnclaimedFees(address token) external view returns (
        uint256 creatorFee0,
        uint256 creatorFee1,
        uint256 protocolFee0,
        uint256 protocolFee1
    ) {
        // Get the token ID
        uint256 tokenId = tokenPositionIds[token];
        if (tokenId == 0) revert InvalidToken();

        // Get the unclaimed fees
        creatorFee0 = creatorUnclaimedFees[tokenId].unclaimed0;
        creatorFee1 = creatorUnclaimedFees[tokenId].unclaimed1;
        protocolFee0 = protocolUnclaimedFees[tokenId].unclaimed0;
        protocolFee1 = protocolUnclaimedFees[tokenId].unclaimed1;
    }

    /// @param token The token address to collect fees for
    function collectFees(address token) internal {
        uint256 tokenId = tokenPositionIds[token];
        if (tokenId == 0) revert InvalidToken();

        // Get total fees
        (uint256 totalFee0, uint256 totalFee1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // Split fees according to configuration
        FeeConfig memory config = tokenFeeConfig[token];
        uint256 creatorFee0 = (totalFee0 * config.creatorLPFeeBps) / 10_000;
        uint256 creatorFee1 = (totalFee1 * config.creatorLPFeeBps) / 10_000;
        uint256 protocolFee0 = totalFee0 - creatorFee0;
        uint256 protocolFee1 = totalFee1 - creatorFee1;

        // Store unclaimed fees
        creatorUnclaimedFees[tokenId].unclaimed0 += uint128(creatorFee0);
        creatorUnclaimedFees[tokenId].unclaimed1 += uint128(creatorFee1);
        protocolUnclaimedFees[tokenId].unclaimed0 += uint128(protocolFee0);
        protocolUnclaimedFees[tokenId].unclaimed1 += uint128(protocolFee1);

        emit FeesCollected(tokenId, creatorFee0, creatorFee1, protocolFee0, protocolFee1);
    }

    /// @param token The token address to claim fees for
    /// @param recipient The recipient of the fees
    function claimCreatorFees(address token, address recipient) external {
        collectFees(token);

        if (msg.sender != tokenFeeConfig[token].creator) revert Unauthorized();
        uint256 tokenId = tokenPositionIds[token];

        UnclaimedFees memory fees = creatorUnclaimedFees[tokenId];
        if (fees.unclaimed0 == 0 && fees.unclaimed1 == 0) revert NoFeesToClaim();

        // Reset unclaimed fees before transfer
        delete creatorUnclaimedFees[tokenId];

        address feeToken = tokenFeeConfig[token].feeToken;

        // Get token addresses in correct order
        (address token0, address token1) = address(token) < address(feeToken) ? (token, address(feeToken)) : (address(feeToken), token);

        // Transfer fees
        if (fees.unclaimed0 > 0) {
            ERC20(token0).transfer(recipient, fees.unclaimed0);
        }
        if (fees.unclaimed1 > 0) {
            ERC20(token1).transfer(recipient, fees.unclaimed1);
        }

        emit FeesClaimed(recipient, tokenId, fees.unclaimed0, fees.unclaimed1);
    }

    /// @notice Claims Protocol Fees to send 🌈 Over the Rainbow 🌈
    /// @param token The token address to claim fees for
    /// @param recipient The recipient of the fees
    function claimProtocolFees(address token, address recipient) external onlyOwner {
        collectFees(token);
        
        uint256 tokenId = tokenPositionIds[token];

        UnclaimedFees memory fees = protocolUnclaimedFees[tokenId];
        if (fees.unclaimed0 == 0 && fees.unclaimed1 == 0) revert NoFeesToClaim();

        // Reset unclaimed fees before transfer
        delete protocolUnclaimedFees[tokenId];

        // Get token addresses in correct order
        address feeToken = tokenFeeConfig[token].feeToken;

        // Get token addresses in correct order
        (address token0, address token1) = address(token) < address(feeToken) ? (token, address(feeToken)) : (address(feeToken), token);

        // Transfer fees
        if (fees.unclaimed0 > 0) {
            ERC20(token0).transfer(recipient, fees.unclaimed0);
        }
        if (fees.unclaimed1 > 0) {
            ERC20(token1).transfer(recipient, fees.unclaimed1);
        }

        emit FeesClaimed(recipient, tokenId, fees.unclaimed0, fees.unclaimed1);
    }

    /*//////////////////////////////////////////////////////////////
                          POSITION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function onERC721Received(address, address, uint256, bytes calldata) external virtual override returns (bytes4) {
        if (msg.sender != address(nonfungiblePositionManager)) {
            revert NotUniswapPositionManager();
        }

        return ERC721TokenReceiver.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                               TICK MATH
    //////////////////////////////////////////////////////////////*/

    /// @param tickSpacing The tick spacing to use
    /// @return The maximum tick that can be used
    function maxUsableTick(int24 tickSpacing) internal pure returns (int24) {
        return (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
    }

    /*//////////////////////////////////////////////////////////////
                                 UTILS
    //////////////////////////////////////////////////////////////*/

    bytes16 private constant HEX_DIGITS = "0123456789abcdef";

    error StringsInsufficientHexLength(bytes32 value, uint256 length);

    /// @param value The value to convert to hex
    /// @param length The length of the hex string
    function toHexString(bytes32 value, uint256 length) internal pure returns (string memory) {
        uint256 localValue = uint256(value);
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = HEX_DIGITS[localValue & 0xf];
            localValue >>= 4;
        }
        if (localValue != 0) {
            revert StringsInsufficientHexLength(value, length);
        }
        return string(buffer);
    }

    /// @notice Predict the address of a token, used to determine salt offchain
    /// @param creator The creator of the token (msg.sender)
    /// @param name The name of the token
    /// @param symbol The symbol of the token
    /// @param merkleroot The merkle root for airdrop claims
    /// @param supply The total supply of the token
    /// @param salt The salt for the token deployment
    function predictTokenAddress(
        address creator,
        string memory name,
        string memory symbol,
        bytes32 merkleroot,
        uint256 supply,
        bytes32 salt
    )
        external
        view
        returns (address token)
    {
        bool hasAirdrop = merkleroot != bytes32(0);
        (, uint256 airdropAmount) = calculateSupplyAllocation(supply, hasAirdrop);

        uint256 id;
        assembly {
            id := chainid()
        }

        string memory tokenURI = string(toHexString(keccak256(abi.encode(creator, salt, name, symbol, merkleroot, supply)), 32));

        bytes memory constructorArgs = abi.encode(name, symbol, string.concat(baseTokenURI, tokenURI), merkleroot, airdropAmount, id);
        bytes32 createSalt = keccak256(abi.encode(creator, salt));

        token = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xFF), address(this), createSalt, keccak256(bytes.concat(type(RainbowSuperToken).creationCode, constructorArgs))
                        )
                    )
                )
            )
        );
    }
}
