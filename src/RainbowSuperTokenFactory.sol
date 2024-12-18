// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";

import {RainbowSuperToken} from "src/RainbowSuperToken.sol";

import {IUniswapV3Pool} from "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "lib/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "v3-periphery/interfaces/INonfungiblePositionManager.sol";

contract RainbowSuperTokenFactory is Owned, ERC721TokenReceiver {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event RainbowSuperTokenCreated(address indexed token, address indexed owner);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/
    /// @dev The canonical Uniswap V3 factory contract.
    IUniswapV3Factory public immutable uniswapV3Factory;

    /// @dev The canonical WETH token contract.
    address public immutable WETH;

    /// @dev The Nonfungible Position Manager contract.
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @dev The mapping of banned names.
    mapping(string => bool) public bannedNames;

    /// @dev The mapping of banned tickers.
    mapping(string => bool) public bannedTickers;

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

    function setMaximumOwnerSupply() external onlyOwner {
    }

    function setProtocolFeeFromSupply() external onlyOwner {}

    function setProtocolLPFeeSplit() external onlyOwner {}

    /// @param name The name of the token to ban
    /// @param status The status of the ban
    function banName(string memory name, bool status) external onlyOwner {
        bannedNames[name] = status;
    }

    /// @param name The name of the token to ban
    /// @param status The status of the ban
    function banTicker(string memory name, bool status) external onlyOwner {
        bannedTickers[name] = status;
    }

    /*//////////////////////////////////////////////////////////////
                         RAINBOW TOKEN LAUNCHER
    //////////////////////////////////////////////////////////////*/
    
    error ReservedName();
    error ReservedTicker();

    error BannedName();
    error BannedTicker();


    function launchRainbowSuperToken(string memory name, string memory symbol, bytes32 merkleroot, uint256 supply, RainbowSuperToken.RainbowTokenMetadata memory metadata) public returns (RainbowSuperToken newToken) {
        if (keccak256(abi.encodePacked(name)) == keccak256(abi.encodePacked("Rainbow"))) {
            revert ReservedName();
        }
        if (keccak256(abi.encodePacked(symbol)) == keccak256(abi.encodePacked("RNBW"))) {
            revert ReservedTicker();
        }

        if (bannedNames[name]) {
            revert BannedName();
        }
        if (bannedTickers[symbol]) {
            revert BannedTicker();
        }

        newToken = new RainbowSuperToken(name, symbol, metadata, merkleroot, supply);

        address pool = uniswapV3Factory.createPool(address(newToken), WETH, UNI_FEE);
        IUniswapV3Pool(pool).initialize(initialSqrtRatio);

        /// Supply the initial liquidity
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(newToken),
            token1: WETH,
            fee: UNI_FEE,
            tickLower: minUsableTick(UNI_TICK_SPACING),
            tickUpper: maxUsableTick(UNI_TICK_SPACING),
            amount0Desired: lpSupply_,
            amount1Desired: ethLpAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });
        token.approve(address(positionManager), lpSupply_);
        (uint256 tokenId,,,) = positionManager.mint{value: ethLpAmount}(params);
    }

    /*//////////////////////////////////////////////////////////////
                          POSITION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    error NotUniswapPositionManager();

    /// @param id The ID of the position to claim fees for
    /// @param recipient The address to send the fees to
    function claimFees(uint256 id, address recipient)
        external
        onlyOwner
        returns (uint256 recipientFee0, uint256 recipientFee1)
    {
        // claim fees
        (recipientFee0, recipientFee1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: id,
                recipient: recipient,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    /// @notice Recieves an ERC721 token from the Nonfungible Position Manager.
    function onERC721Received(address, address, uint256 id, bytes calldata)
        external
        virtual
        override
        returns (bytes4)
    {
        if (msg.sender != address(nonfungiblePositionManager)) {
            revert NotUniswapPositionManager();
        }

        return ERC721TokenReceiver.onERC721Received.selector;
    }
}
