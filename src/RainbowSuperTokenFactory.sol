// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Owned } from "lib/solmate/src/auth/Owned.sol";
import { ERC721TokenReceiver } from "solmate/tokens/ERC721.sol";
import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";

import { RainbowSuperToken } from "src/RainbowSuperToken.sol";

import { TickMath } from "vendor/v3-core/libraries/TickMath.sol";
import { FixedPointMathLib } from "lib/solmate/src/utils/FixedPointMathLib.sol";

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
    error InvalidToken();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event RainbowSuperTokenCreated(address indexed token, address indexed owner);
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
    address public immutable WETH;

    /// @dev The Nonfungible Position Manager contract
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

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

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _uniswapV3Factory, address _nonfungiblePositionManager, address _weth) Owned(msg.sender) {
        WETH = _weth;
        uniswapV3Factory = IUniswapV3Factory(_uniswapV3Factory);
        nonfungiblePositionManager = INonfungiblePositionManager(_nonfungiblePositionManager);
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

    function banName(string memory name, bool status) external onlyOwner {
        bannedNames[name] = status;
    }

    function banTicker(string memory ticker, bool status) external onlyOwner {
        bannedTickers[ticker] = status;
    }

    function setNewTickSpacing(uint24 newPoolFee) external onlyOwner {
        POOL_FEE = newPoolFee;
        TICK_SPACING = uniswapV3Factory.feeAmountTickSpacing(newPoolFee);
    }

    /*//////////////////////////////////////////////////////////////
                         RAINBOW TOKEN LAUNCHER
    //////////////////////////////////////////////////////////////*/

    function launchRainbowSuperToken(
        string memory name,
        string memory symbol,
        bytes32 merkleroot,
        uint256 supply,
        int24 initialTick,
        bytes32 salt,
        bool hasAirdrop,
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
        newToken = new RainbowSuperToken{salt : keccak256(abi.encode(msg.sender, salt))}(name, symbol, metadata, merkleroot, airdropAmount);

        if (address(newToken) > address(WETH)) {
            revert IncorrectSalt();
        }

        newToken.mint(msg.sender, creatorAmount);

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

        address pool = uniswapV3Factory.createPool(address(newToken), WETH, POOL_FEE);

        uint160 initialSqrtRatio = initialTick.getSqrtRatioAtTick();
        IUniswapV3Pool(pool).initialize(initialSqrtRatio);
        
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

        emit RainbowSuperTokenCreated(address(newToken), msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            FEE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function calculateSupplyAllocation(
        uint256 totalSupply,
        bool hasAirdrop
    )
        public
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

    function claimCreatorFees(address token, address recipient) external {
        if (msg.sender != tokenFeeConfig[token].creator) revert Unauthorized();
        uint256 tokenId = tokenPositionIds[token];

        UnclaimedFees memory fees = creatorUnclaimedFees[tokenId];
        if (fees.unclaimed0 == 0 && fees.unclaimed1 == 0) revert NoFeesToClaim();

        // Reset unclaimed fees before transfer
        delete creatorUnclaimedFees[tokenId];

        // Get token addresses in correct order
        (address token0, address token1) = address(msg.sender) < WETH ? (msg.sender, WETH) : (WETH, msg.sender);

        // Transfer fees
        if (fees.unclaimed0 > 0) {
            ERC20(token0).transfer(recipient, fees.unclaimed0);
        }
        if (fees.unclaimed1 > 0) {
            ERC20(token1).transfer(recipient, fees.unclaimed1);
        }

        emit FeesClaimed(recipient, tokenId, fees.unclaimed0, fees.unclaimed1);
    }

    function claimProtocolFees(uint256 tokenId, address recipient) external onlyOwner {
        UnclaimedFees memory fees = protocolUnclaimedFees[tokenId];
        if (fees.unclaimed0 == 0 && fees.unclaimed1 == 0) revert NoFeesToClaim();

        // Reset unclaimed fees before transfer
        delete protocolUnclaimedFees[tokenId];

        // Get token addresses in correct order
        (address token0, address token1) = address(msg.sender) < WETH ? (msg.sender, WETH) : (WETH, msg.sender);

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

    function minUsableTick(int24 tickSpacing) internal pure returns (int24) {
        return (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
    }

    function maxUsableTick(int24 tickSpacing) internal pure returns (int24) {
        return (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
    }

    function getTickFromPrice(uint256 tokenSupply, uint256 wethMarketCap) internal pure returns (int24 tick) {

    }
}
