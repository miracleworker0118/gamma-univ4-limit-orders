// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LimitOrderHook} from "src/LimitOrderHook.sol";
import {LimitOrderManager} from "src/LimitOrderManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ILimitOrderManager} from "src/ILimitOrderManager.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import "../src/TickLibrary.sol";
import {LimitOrderLens} from "src/LimitOrderLens.sol";
import {DetailedUserPosition} from "src/LimitOrderLens.sol";


contract LimitOrderLensTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    uint256 public HOOK_FEE_PERCENTAGE = 50000;
    uint256 public constant FEE_DENOMINATOR = 100000;
    uint256 internal constant Q128 = 1 << 128;
    LimitOrderHook hook;
    ILimitOrderManager limitOrderManager;
    LimitOrderManager orderManager;
    LimitOrderLens lens;
    address public treasury;
    PoolKey poolKey;
    
    // To grant roles
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Set up treasury address
        treasury = makeAddr("treasury");

        // First deploy the LimitOrderManager
        orderManager = new LimitOrderManager(
            address(manager), // The pool manager from Deployers
            treasury,
            address(this) // This test contract as owner
        );

        // Deploy LimitOrderLens for querying position data
        lens = new LimitOrderLens(
            address(orderManager),
            address(this)  // This test contract as owner
        );

        // Deploy hook with proper flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(flags);

        // Deploy the hook with the LimitOrderManager address
        deployCodeTo(
            "LimitOrderHook.sol",
            abi.encode(address(manager), address(orderManager), address(this)),
            hookAddress
        );
        hook = LimitOrderHook(hookAddress);
        
        // Set the reference to the manager interface
        limitOrderManager = ILimitOrderManager(address(orderManager));
        limitOrderManager.setExecutablePositionsLimit(50);
        limitOrderManager.setHook(address(hook));
        
        // Initialize pool with dynamic fee flag and tickSpacing of 10
        int24 tickSpacing = 20;
        poolKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // signal that the pool has a dynamic fee
            tickSpacing,
            IHooks(hook)
        );
        
        // Initialize the pool with 1:1 price
        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;
        manager.initialize(poolKey, sqrtPriceX96);
        
        orderManager.setWhitelistedPool(poolKey.toId(), true);

        // Approve tokens to manager
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(limitOrderManager), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(limitOrderManager), type(uint256).max);

        // Add initial liquidity for testing
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -1000,
                tickUpper: 1000,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ""
        );
    }
    

    
    // Helper function to perform a swap
    function _swap(int24 limitTick, bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        uint160 priceLimit = TickMath.getSqrtPriceAtTick(limitTick);
        BalanceDelta delta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,  // swapping token0 for token1, price goes down
                amountSpecified: amount,
                sqrtPriceLimitX96: priceLimit
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        
        // Return the BalanceDelta result
        return delta;
    }
    
    // Helper function to get position key
    function _getPositionKey(int24 bottomTick, int24 topTick, bool isToken0) internal returns (bytes32) {
        bytes32 baseKey = bytes32(
            uint256(uint24(bottomTick)) << 232 |
            uint256(uint24(topTick)) << 208 |
            uint256(isToken0 ? 1 : 0)
        );
        
        uint256 nonce = limitOrderManager.currentNonce(poolKey.toId(), baseKey);
        
        return bytes32(
            uint256(uint24(bottomTick)) << 232 |
            uint256(uint24(topTick)) << 208 |
            uint256(nonce) << 8 |
            uint256(isToken0 ? 1 : 0)
        );
    }
    
    // Test the getTickInfosAroundCurrent function
    function testGetTickInfosAroundCurrent() public {
        // Set up some limit orders at various ticks to create an interesting orderbook
        
        // Create a pool key mapping in the lens contract first
        lens.addPoolId(poolKey.toId(), poolKey);
        
        // Get min and max ticks for token0 and token1
        (int24 minTickToken0, int24 maxTickToken0) = lens.getMinAndMaxTick(poolKey.toId(), true);
        (int24 minTickToken1, int24 maxTickToken1) = lens.getMinAndMaxTick(poolKey.toId(), false);
        console.log("minTickToken0:", minTickToken0);
        console.log("maxTickToken0:", maxTickToken0);
        console.log("minTickToken1:", minTickToken1);
        console.log("maxTickToken1:", maxTickToken1);
        // Create token0 scale orders - from minTick to 220
        limitOrderManager.createScaleOrders(
            true,          // isToken0
            minTickToken0, // bottomTick
            int24(240),           // topTick
            10 ether,            // totalAmount
            uint256(10),      // totalAmount
            uint256(1e18),          // skew
            poolKey        // poolKey
        );
        
        // Create token1 scale orders - from -200 to maxTick
        limitOrderManager.createScaleOrders(
            false,         // isToken0
            int24(-220),          // bottomTick
            int24(maxTickToken1), // topTick
            10 ether,      // totalAmount
            uint256(10),            // totalOrders
            uint256(1e18),          // skew
            poolKey        // poolKey
        );
        
        // Get current state
        (uint160 sqrtPriceX96, int24 currentTick, , ) = StateLibrary.getSlot0(manager, poolKey.toId());
        console.log("Current tick:", currentTick);
        
        // Test with numTicks = 600
        (, , LimitOrderLens.TickInfo[] memory tickInfos) = 
            lens.getTickInfosAroundCurrent(poolKey.toId(), 240);
            
        // Log the total number of tick infos returned
        console.log("Total tick infos returned:", tickInfos.length);
        
        // Log all tick info structs
        for (uint i = 0; i < tickInfos.length; i++) {
            console.log("Tick", i, ":");
            console.log("  tick:", tickInfos[i].tick);
            console.log("  token0Amount:", tickInfos[i].token0Amount);
            console.log("  token1Amount:", tickInfos[i].token1Amount);
            console.log("  totalTokenAmountsinToken1:", tickInfos[i].totalTokenAmountsinToken1);
        }
        
        // Get all user positions and log details
        DetailedUserPosition[] memory positions = lens.getAllUserPositions(address(this));
        console.log("Total positions created:", positions.length);
        
        // Log each position's details
        for (uint i = 0; i < positions.length; i++) {
            console.log("Position", i, ":");
            console.log("  isToken0:", positions[i].isToken0 ? "true" : "false");
            console.log("  bottomTick:", positions[i].bottomTick);
            console.log("  topTick:", positions[i].topTick);
            console.log("  liquidity:", positions[i].liquidity);
            console.log("  orderSize:", positions[i].orderSize);
            console.log("  positionToken0Principal:", positions[i].positionToken0Principal);
            console.log("  positionToken1Principal:", positions[i].positionToken1Principal);
            console.log("  claimable:", positions[i].claimable ? "true" : "false");
        }
    }
}

