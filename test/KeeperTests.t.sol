// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
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
import {ILimitOrderManager} from "src/ILimitOrderManager.sol";
import {PositionManagement} from "src/PositionManagement.sol";

contract KeeperTests is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    LimitOrderHook hook;
    ILimitOrderManager limitOrderManager;
    address public treasury;
    PoolKey poolKey;

function setUp() public {
    deployFreshManagerAndRouters();
    (currency0, currency1) = deployMintAndApprove2Currencies();

    // Set up treasury address
    treasury = makeAddr("treasury");

    // First deploy the LimitOrderManager
    LimitOrderManager orderManager = new LimitOrderManager(
        address(manager), // The pool manager from Deployers
        treasury,
        address(this) // This test contract as owner
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
    limitOrderManager.setExecutablePositionsLimit(5);
    limitOrderManager.setHook(address(hook));
    // Initialize pool with 1:1 price
    (poolKey,) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);

    orderManager.setWhitelistedPool(poolKey.toId(), true);
    // Approve tokens to manager
    IERC20Minimal(Currency.unwrap(currency0)).approve(address(limitOrderManager), type(uint256).max);
    IERC20Minimal(Currency.unwrap(currency1)).approve(address(limitOrderManager), type(uint256).max);

    // Add initial liquidity for testing
    modifyLiquidityRouter.modifyLiquidity(
        poolKey,
        IPoolManager.ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: 100 ether,
            salt: bytes32(0)
        }),
        ""
    );
}

    function test_keeper_execution() public {
        // Setup keeper
        address keeper = makeAddr("keeper");
        limitOrderManager.setKeeper(keeper, true);
        
        // Setup initial amounts
        deal(Currency.unwrap(currency0), address(this), 100 ether);
        deal(Currency.unwrap(currency1), address(this), 100 ether);

        // Get current tick
        (, int24 currentTick,,) = StateLibrary.getSlot0(hook.poolManager(), poolKey.toId());
        
        // Create 5 limit orders at different ticks
        for(uint i = 0; i < 7; i++) {
            int24 tickOffset = int24(int256(120 * (i + 2))); // Using 120 (2 * tickSpacing) and starting from 2
            
            // ILimitOrderManager.LimitOrderParams memory params = ILimitOrderManager.LimitOrderParams({
            //     isToken0: true,
            //     isRange: false,
            //     targetTick: currentTick + tickOffset,
            //     amount: 1 ether
            // });
            
            limitOrderManager.createLimitOrder(true, (currentTick + tickOffset), 1 ether, poolKey);
            console.log("Order number:", i);
            console.log("Target tick:", currentTick + tickOffset);
        }

        // Perform swap that should trigger all positions
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -10 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(currentTick + 1000) // Well beyond all positions
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );

        // After swap, check position states
        PoolId poolId = poolKey.toId();
        ILimitOrderManager.PositionInfo[] memory positions = limitOrderManager.getUserPositions(address(this), poolId);
        
        // Count active positions
        uint256 activePositions = 0;
        uint256 waitingForKeeper = 0;
        for(uint i = 0; i < positions.length; i++) {
            (,, bool isActive, bool isWaitingKeeper,) = limitOrderManager.positionState(poolId, positions[i].positionKey);
            if(isActive) activePositions++;
            if(isWaitingKeeper) waitingForKeeper++;
        }

        console.log("Active positions:", activePositions);
        console.log("Positions waiting for keeper:", waitingForKeeper);
        
        // Should have 2 positions waiting for keeper and inactive positions
        assertEq(waitingForKeeper, 2, "Should have 2 positions waiting for keeper");
        assertEq(activePositions, 2, "Should have 2 active positions");

        // Try to execute as non-keeper - should revert
        ILimitOrderManager.PositionTickRange[] memory leftoverPositions = getLeftoverPositions(poolId);
        vm.expectRevert();
        limitOrderManager.executeOrderByKeeper(poolKey, leftoverPositions);

        // Execute remaining positions as keeper
        vm.prank(keeper);
        limitOrderManager.executeOrderByKeeper(poolKey, leftoverPositions);

        // Verify all positions are now inactive
        for(uint i = 0; i < positions.length; i++) {
            (,, bool isActive, bool isWaitingKeeper,) = limitOrderManager.positionState(poolId, positions[i].positionKey);
            assertFalse(isActive, "Position should be inactive");
            assertFalse(isWaitingKeeper, "Position should not be waiting for keeper");
        }
    }

    function test_keeper_management() public {
        // Test adding keepers
        address keeper1 = makeAddr("keeper1");
        address keeper2 = makeAddr("keeper2");
        
        // Add keepers
        limitOrderManager.setKeeper(keeper1, true);
        limitOrderManager.setKeeper(keeper2, true);
        
        // Verify keepers are set
        assertTrue(limitOrderManager.isKeeper(keeper1), "Keeper1 should be set");
        assertTrue(limitOrderManager.isKeeper(keeper2), "Keeper2 should be set");
        
        // Test removing keepers
        limitOrderManager.setKeeper(keeper1, false);
        
        // Verify keeper1 is removed but keeper2 remains
        assertFalse(limitOrderManager.isKeeper(keeper1), "Keeper1 should be removed");
        assertTrue(limitOrderManager.isKeeper(keeper2), "Keeper2 should still be active");
        
        // // Test zero address rejection
        // address[] memory invalidKeepers = new address[](1);
        // invalidKeepers[0] = address(0);
        
        // vm.expectRevert();
        // limitOrderManager.flipKeeper(invalidKeepers);
    }

    function test_keeper_non_executable_positions() public {
        // Setup keeper
        address keeper = makeAddr("keeper");
        limitOrderManager.setKeeper(keeper, true);
        
        deal(Currency.unwrap(currency0), address(this), 100 ether);
        deal(Currency.unwrap(currency1), address(this), 100 ether);

        (, int24 currentTick,,) = StateLibrary.getSlot0(hook.poolManager(), poolKey.toId());
        
        // Create 3 orders
        for(uint i = 0; i < 3; i++) {
            int24 tickOffset = int24(int256(120 * (i + 1))); // Proper conversion
            // ILimitOrderManager.LimitOrderParams memory params = ILimitOrderManager.LimitOrderParams({
            //     isToken0: true,
            //     isRange: false,
            //     targetTick: currentTick + tickOffset,
            //     amount: 1 ether
            // });
            limitOrderManager.createLimitOrder(true, (currentTick + tickOffset), 1 ether, poolKey);
        }

        // Perform small swap that marks positions for keeper but doesn't reach execution price
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(currentTick + 30) // Not reaching any position
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );

        // Try to execute with keeper
        PoolId poolId = poolKey.toId();
        ILimitOrderManager.PositionTickRange[] memory leftoverPositions = getLeftoverPositions(poolId);
        
        vm.prank(keeper);
        limitOrderManager.executeOrderByKeeper(poolKey, leftoverPositions);

        // Get all position keys and verify their states
        ILimitOrderManager.PositionInfo[] memory positions = limitOrderManager.getUserPositions(address(this), poolId);
        
        // Count active positions and waiting positions
        uint256 activePositions = 0;
        uint256 waitingForKeeper = 0;
        for(uint i = 0; i < positions.length; i++) {
            (,, bool isActive, bool isWaitingKeeper,) = limitOrderManager.positionState(poolId, positions[i].positionKey);
            if(isActive) activePositions++;
            if(isWaitingKeeper) waitingForKeeper++;
        }

        // All positions should still be active but none should be waiting for keeper
        assertEq(activePositions, 3, "All positions should still be active");
        assertEq(waitingForKeeper, 0, "No positions should be waiting for keeper");

        // Double check each position's state individually
        for(uint i = 0; i < positions.length; i++) {
            (,, bool isActive, bool isWaitingKeeper,) = limitOrderManager.positionState(poolId, positions[i].positionKey);
            assertTrue(isActive, "Position should be active");
            assertFalse(isWaitingKeeper, "Position should not be waiting for keeper");
        }
    }

    function test_keeper_set_to_false() public {
        // Setup keeper
        address keeper = makeAddr("keeper");
        limitOrderManager.setKeeper(keeper, true);
        
        // Set executable positions limit to 3
        limitOrderManager.setExecutablePositionsLimit(3);
        
        deal(Currency.unwrap(currency0), address(this), 100 ether);
        deal(Currency.unwrap(currency1), address(this), 100 ether);

        (, int24 currentTick,,) = StateLibrary.getSlot0(manager, poolKey.toId());
        
        // Create 5 orders
        for(uint i = 0; i < 5; i++) {
            int24 tickOffset = int24(int256(120 * (i + 1))); // Using 120 to space them out
            // ILimitOrderManager.LimitOrderParams memory params = ILimitOrderManager.LimitOrderParams({
            //     isToken0: true,
            //     isRange: false,
            //     targetTick: currentTick + tickOffset,
            //     amount: 1 ether
            // });
            limitOrderManager.createLimitOrder(true, (currentTick + tickOffset), 1 ether, poolKey);
        }

        // First swap that should trigger all positions and make 2 wait for keeper
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -10 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(currentTick + 1000) // Beyond all positions
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );

        // Check position states after first swap
        PoolId poolId = poolKey.toId();
        ILimitOrderManager.PositionInfo[] memory positions = limitOrderManager.getUserPositions(address(this), poolId);
        
        // Count active positions and waiting positions after first swap
        uint256 activePositions = 0;
        uint256 waitingForKeeper = 0;
        for(uint i = 0; i < positions.length; i++) {
            (,, bool isActive, bool isWaitingKeeper,) = limitOrderManager.positionState(poolId, positions[i].positionKey);
            if(isActive) activePositions++;
            if(isWaitingKeeper) waitingForKeeper++;
        }

        // Should have 2 positions waiting for keeper
        assertEq(waitingForKeeper, 2, "Should have 2 positions waiting for keeper");
        assertEq(activePositions, 2, "Should have 2 active positions");

        // Now swap back so positions are no longer executable
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 12 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(currentTick) // Back to starting point
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );

        // Try to execute with keeper after price moved back
        ILimitOrderManager.PositionTickRange[] memory leftoverPositions = getLeftoverPositions(poolId);
        vm.prank(keeper);
        limitOrderManager.executeOrderByKeeper(poolKey, leftoverPositions);

        // Check final states
        waitingForKeeper = 0;
        activePositions = 0;
        for(uint i = 0; i < positions.length; i++) {
            (,, bool isActive, bool isWaitingKeeper,) = limitOrderManager.positionState(poolId, positions[i].positionKey);
            if(isActive) activePositions++;
            if(isWaitingKeeper) waitingForKeeper++;
        }

        // Should have no positions waiting for keeper, but positions should still be active
        assertEq(waitingForKeeper, 0, "Should have no positions waiting for keeper");
        assertEq(activePositions, 2, "Should still have 2 active positions");

        // Double check each remaining position's state
        for(uint i = 0; i < positions.length; i++) {
            (,, bool isActive, bool isWaitingKeeper,) = limitOrderManager.positionState(poolId, positions[i].positionKey);
            if(isActive) {
                assertFalse(isWaitingKeeper, "Active position should not be waiting for keeper");
            }
        }
    }



    function getLeftoverPositions(PoolId poolId) internal view returns (ILimitOrderManager.PositionTickRange[] memory) {
        // Get user position keys
        ILimitOrderManager.PositionInfo[] memory positions = limitOrderManager.getUserPositions(address(this), poolId);
        
        // First count how many positions are waiting for keeper
        uint256 waitingCount = 0;
        for(uint i = 0; i < positions.length; i++) {
            (,, bool isActive, bool isWaitingKeeper,) = limitOrderManager.positionState(poolId, positions[i].positionKey);
            if(isWaitingKeeper) {
                waitingCount++;
            }
        }
        
        // Create array of correct size
        ILimitOrderManager.PositionTickRange[] memory leftoverPositions = new ILimitOrderManager.PositionTickRange[](waitingCount);
        
        // Fill array only with positions that are waiting for keeper
        uint256 posIndex = 0;
        for(uint i = 0; i < positions.length; i++) {
            (,, bool isActive, bool isWaitingKeeper,) = limitOrderManager.positionState(poolId, positions[i].positionKey);
            if(isWaitingKeeper) {
                (int24 bottomTick, int24 topTick, bool isToken0,) = _decodePositionKey(positions[i].positionKey);
                leftoverPositions[posIndex] = ILimitOrderManager.PositionTickRange({
                    bottomTick: bottomTick,
                    topTick: topTick,
                    isToken0: isToken0
                });
                posIndex++;
            }
        }
        
        return leftoverPositions;
    }

    // Helper functions
    function getBasePositionKey(
        int24 bottomTick,
        int24 topTick,
        bool isToken0
    ) internal pure returns (bytes32) {
        return bytes32(
            uint256(uint24(bottomTick)) << 232 |
            uint256(uint24(topTick)) << 208 |
            uint256(isToken0 ? 1 : 0)
        );
    }

    function getPositionKey(
        int24 bottomTick,
        int24 topTick,
        bool isToken0,
        uint256 nonce
    ) internal pure returns (bytes32) {
        return bytes32(
            uint256(uint24(bottomTick)) << 232 |
            uint256(uint24(topTick)) << 208 |
            uint256(nonce) << 8 |
            uint256(isToken0 ? 1 : 0)
        );
    }

    // function getPositionsForKeeper() internal view returns (ILimitOrderManager.PositionTickRange[] memory) {
    //     ILimitOrderManager.PositionInfo[] memory positions = limitOrderManager.getUserPositions(
    //         address(this), 
    //         poolKey.toId()
    //     );
        
    //     ILimitOrderManager.PositionTickRange[] memory tickRanges = 
    //         new ILimitOrderManager.PositionTickRange[](positions.length);
        
    //     for(uint i = 0; i < positions.length; i++) {
    //         tickRanges[i] = ILimitOrderManager.PositionTickRange({
    //             bottomTick: positions[i].bottomTick,
    //             topTick: positions[i].topTick,
    //             isToken0: positions[i].isToken0
    //         });
    //     }
        
    //     return tickRanges;
    // }

    function _decodePositionKey(bytes32 key) internal pure returns (
        int24 bottomTick,
        int24 topTick,
        bool isToken0,
        uint256 nonce
    ) {
        uint256 value = uint256(key);
        return (
            int24(uint24(value >> 232)),          // bottomTick
            int24(uint24(value >> 208)),          // topTick
            (value & 1) == 1,                     // isToken0
            (value >> 8) & ((1 << 200) - 1)       // nonce (200 bits)
        );
    }
}