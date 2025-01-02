// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Owned } from "lib/solmate/src/auth/Owned.sol";
import { ERC721TokenReceiver } from "solmate/tokens/ERC721.sol";
import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";

import { RainbowSuperToken } from "src/RainbowSuperToken.sol";

import { TickMath } from "vendor/v3-core/libraries/TickMath.sol";
import { FixedPointMathLib } from "lib/solmate/src/utils/FixedPointMathLib.sol";

import { ISwapRouter } from "vendor/v3-periphery/interfaces/ISwapRouter.sol";

import { IWETH9 } from "vendor/v3-periphery/interfaces/external/IWETH9.sol";
import { IUniswapV3Pool } from "vendor/v3-core/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "vendor/v3-core/interfaces/IUniswapV3Factory.sol";
import { INonfungiblePositionManager } from "vendor/v3-periphery/interfaces/INonfungiblePositionManager.sol";

/// @title RainbowSuperTokenFactory
/// @author CopyPaste - for Rainbow with love <3
/// @notice A factory contract for creating RainbowSuperTokens and managing their liquidity positions.
contract RainbowSuperTokenFactory is Owned, ERC721TokenReceiver {
    using TickMath for int24;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ReservedName();
    error ReservedTicker();
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

    event RainbowSuperTokenCreated(address indexed token, address indexed owner, address indexed creator);
    event FeeConfigUpdated(address indexed token, FeeConfig config);
    event FeesCollected(uint256 indexed tokenId, uint256 creatorFee0, uint256 creatorFee1, uint256 protocolFee0, uint256 protocolFee1);
    event FeesClaimed(address indexed recipient, uint256 indexed tokenId, uint256 amount0, uint256 amount1);

    /*//////////////////////////////////////////////////////////////
                              FEE CONFIG
    //////////////////////////////////////////////////////////////*/

    struct FeeConfig {
        // Creator's share of LP fees (in basis points, max 10000)
        uint16 creatorLPFeeBps;
        // Protocol's base fee from initial supply (in basis points)
        uint16 protocolBaseBps;
        // Creator's fee from initial supply (in basis points)
        uint16 creatorBaseBps;
        // Airdrop allocation from initial supply (in basis points)
        uint16 airdropBps;
        // Whether this token has airdrop enabled
        bool hasAirdrop;
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

    /// @dev The Nonfungible Position Manager contract
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @dev The Uniswap V3 SwapRouter contract
    ISwapRouter public immutable swapRouter;

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

    /// @dev The Uniswap V3 Pool fee
    uint24 public POOL_FEE = 10_000;

    /// @dev The Uniswap V3 Tick spacing
    int24 public TICK_SPACING = 200;

    /// @dev Target market cap for new tokens in USD (30,000)
    uint256 public constant TARGET_MARKET_CAP = 30_000 * 1e18;

    /// @dev ETH price in USD (3,500)
    uint256 public constant ETH_PRICE = 3500 * 1e18;

    /// @dev Default fee configuration
    FeeConfig public defaultFeeConfig = FeeConfig({
        creatorLPFeeBps: 2000, // 20% of LP fees to creator
        protocolBaseBps: 69, // 0.69% to protocol if no airdrop
        creatorBaseBps: 46, // 0.46% to creator with airdrop
        airdropBps: 23, // 0.23% to airdrop
        hasAirdrop: false,
        creator: address(0)
    });

    bytes32 public constant RainbowSuperTokenContractCodeHash = keccak256(type(RainbowSuperToken).creationCode);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _uniswapV3Factory, address _nonfungiblePositionManager, address _swapRouter, address _weth) Owned(msg.sender) {
        WETH = IWETH9(payable(_weth));
        swapRouter = ISwapRouter(_swapRouter);
        uniswapV3Factory = IUniswapV3Factory(_uniswapV3Factory);
        nonfungiblePositionManager = INonfungiblePositionManager(_nonfungiblePositionManager);

        WETH.approve(_swapRouter, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                             ADMIN CONTROLS
    //////////////////////////////////////////////////////////////*/

    function setDefaultFeeConfig(FeeConfig calldata newConfig) external onlyOwner {
        if (newConfig.creatorLPFeeBps > 10_000) revert InvalidFeeSplit();
        if (newConfig.protocolBaseBps + newConfig.creatorBaseBps + newConfig.airdropBps > 10_000) {
            revert InvalidSupplyAllocation();
        }
        defaultFeeConfig = newConfig;
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
    /// @param hasAirdrop Whether the token has airdrop enabled
    /// @param deployer The address to grant the initial tokens to
    ///
    /// @return The newly created RainbowSuperToken
    function launchRainbowSuperTokenAndBuy(
        string memory name,
        string memory symbol,
        bytes32 merkleroot,
        uint256 supply,
        int24 initialTick,
        bytes32 salt,
        bool hasAirdrop,
        address deployer,
        RainbowSuperToken.RainbowTokenMetadata memory metadata
    )
        external
        payable
        returns (RainbowSuperToken)
    {
        if (msg.value == 0) revert InsufficientFunds();
        WETH.deposit{ value: msg.value }();

        RainbowSuperToken token = launchRainbowSuperToken(name, symbol, merkleroot, supply, initialTick, salt, hasAirdrop, deployer, metadata);

        ISwapRouter.ExactInputSingleParams memory swapParamsToken = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(WETH), // The token we are exchanging from (ETH wrapped as WETH)
            tokenOut: address(token), // The token we are exchanging to
            fee: POOL_FEE, // The pool fee
            recipient: deployer, // The recipient address
            deadline: block.timestamp, // The deadline for the swap
            amountIn: msg.value, // The amount of ETH (WETH) to be swapped
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
    /// @param hasAirdrop Whether the token has airdrop enabled
    /// @param deployer The address to grant the initial tokens to
    ///
    /// @return newToken The newly created RainbowSuperToken
    function launchRainbowSuperToken(
        string memory name,
        string memory symbol,
        bytes32 merkleroot,
        uint256 supply,
        int24 initialTick,
        bytes32 salt,
        bool hasAirdrop,
        address deployer,
        RainbowSuperToken.RainbowTokenMetadata memory metadata
    )
        public
        returns (RainbowSuperToken newToken)
    {
        // Name and ticker checks
        if (keccak256(abi.encodePacked(name)) == keccak256(abi.encodePacked("Rainbow"))) {
            revert ReservedName();
        }
        if (keccak256(abi.encodePacked(symbol)) == keccak256(abi.encodePacked("RNBW"))) {
            revert ReservedTicker();
        }
        if (bannedNames[name]) revert BannedName();
        if (bannedTickers[symbol]) revert BannedTicker();

        (uint256 lpSupply, uint256 creatorAmount, uint256 airdropAmount) = calculateSupplyAllocation(supply, hasAirdrop);

        // Create token
        newToken = new RainbowSuperToken{ salt: keccak256(abi.encode(deployer, salt)) }(name, symbol, metadata, merkleroot, airdropAmount);

        if (address(newToken) > address(WETH)) {
            revert IncorrectSalt();
        }

        newToken.mint(deployer, creatorAmount);

        // Set up fee configuration
        FeeConfig memory config = FeeConfig({
            creatorLPFeeBps: defaultFeeConfig.creatorLPFeeBps,
            protocolBaseBps: defaultFeeConfig.protocolBaseBps,
            creatorBaseBps: defaultFeeConfig.creatorBaseBps,
            airdropBps: defaultFeeConfig.airdropBps,
            hasAirdrop: hasAirdrop,
            creator: msg.sender
        });
        tokenFeeConfig[address(newToken)] = config;

        IUniswapV3Pool pool = IUniswapV3Pool(uniswapV3Factory.createPool(address(newToken), address(WETH), POOL_FEE));

        uint160 initialSqrtRatio = initialTick.getSqrtRatioAtTick();
        pool.initialize(initialSqrtRatio);

        newToken.mint(address(this), lpSupply);

        // Provide initial liquidity
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(newToken),
            token1: address(WETH),
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

        emit RainbowSuperTokenCreated(address(newToken), deployer, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            FEE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate the allocation of supply for LP, creator and airdrop
    /// @param totalSupply The total supply of the token
    /// @param hasAirdrop Whether the token has airdrop enabled
    ///
    /// @return lpAmount The amount of tokens allocated to LP
    /// @return creatorAmount The amount of tokens allocated to the creator
    /// @return airdropAmount The amount of tokens allocated to airdrop
    function calculateSupplyAllocation(
        uint256 totalSupply,
        bool hasAirdrop
    )
        internal
        view
        returns (uint256 lpAmount, uint256 creatorAmount, uint256 airdropAmount)
    {
        if (hasAirdrop) {
            creatorAmount = (totalSupply * defaultFeeConfig.creatorBaseBps) / 10_000;
            airdropAmount = (totalSupply * defaultFeeConfig.airdropBps) / 10_000;
        } else {
            creatorAmount = (totalSupply * defaultFeeConfig.protocolBaseBps) / 10_000;
            airdropAmount = 0;
        }
        lpAmount = totalSupply - creatorAmount - airdropAmount;
    }

    /// @param token The token address to collect fees for
    function collectFees(address token) external {
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
        if (msg.sender != tokenFeeConfig[token].creator) revert Unauthorized();
        uint256 tokenId = tokenPositionIds[token];

        UnclaimedFees memory fees = creatorUnclaimedFees[tokenId];
        if (fees.unclaimed0 == 0 && fees.unclaimed1 == 0) revert NoFeesToClaim();

        // Reset unclaimed fees before transfer
        delete creatorUnclaimedFees[tokenId];

        // Get token addresses in correct order
        (address token0, address token1) = address(msg.sender) < address(WETH) ? (msg.sender, address(WETH)) : (address(WETH), msg.sender);

        // Transfer fees
        if (fees.unclaimed0 > 0) {
            ERC20(token0).transfer(recipient, fees.unclaimed0);
        }
        if (fees.unclaimed1 > 0) {
            ERC20(token1).transfer(recipient, fees.unclaimed1);
        }

        emit FeesClaimed(recipient, tokenId, fees.unclaimed0, fees.unclaimed1);
    }

    /// @param tokenId The token address to claim fees for
    /// @param recipient The recipient of the fees
    function claimProtocolFees(uint256 tokenId, address recipient) external onlyOwner {
        UnclaimedFees memory fees = protocolUnclaimedFees[tokenId];
        if (fees.unclaimed0 == 0 && fees.unclaimed1 == 0) revert NoFeesToClaim();

        // Reset unclaimed fees before transfer
        delete protocolUnclaimedFees[tokenId];

        // Get token addresses in correct order
        (address token0, address token1) = address(msg.sender) < address(WETH) ? (msg.sender, address(WETH)) : (address(WETH), msg.sender);

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

    /// @notice Predict the address of a token, used to determine salt offchain
    /// @param creator The creator of the token (msg.sender)
    /// @param name The name of the token
    /// @param symbol The symbol of the token
    /// @param merkleroot The merkle root for airdrop claims
    /// @param supply The total supply of the token
    /// @param initialTick The initial tick for the liquidity position
    /// @param salt The salt for the token deployment
    /// @param hasAirdrop Whether the token has airdrop enabled
    /// @param metadata The metadata for the token
    function predictTokenAddress(
        address creator,
        string memory name,
        string memory symbol,
        bytes32 merkleroot,
        uint256 supply,
        int24 initialTick,
        bytes32 salt,
        bool hasAirdrop,
        RainbowSuperToken.RainbowTokenMetadata memory metadata
    )
        external
        view
        returns (address token)
    {
        bytes memory constructorArgs = abi.encode(name, symbol, merkleroot, supply, initialTick, salt, hasAirdrop, metadata);
        bytes32 createSalt = keccak256(abi.encodePacked(creator, constructorArgs));

        token = address(
            uint160(
                uint256(
                    keccak256(bytes.concat(bytes32(uint256(uint160(address(this)))), createSalt, RainbowSuperTokenContractCodeHash, keccak256(constructorArgs)))
                )
            )
        );

        return address(uint160(uint256(keccak256(abi.encodePacked(RainbowSuperTokenContractCodeHash, creator, salt)))));
    }
}
