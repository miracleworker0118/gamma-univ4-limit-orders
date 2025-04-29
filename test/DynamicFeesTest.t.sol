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


contract DynamicFeesTest is Test, Deployers {
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
        int24 tickSpacing = 10;
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
    
    function test_create_and_execute_order_with_default_fee() public {
        // Get current fee to confirm it's 0
        (,,, uint24 fee) = StateLibrary.getSlot0(manager, poolKey.toId());
        console.log("Initial LP fee:");
        console.log(fee);
        assertEq(fee, 0, "Initial fee should be 0");
        
        // Create a limit order
        deal(Currency.unwrap(currency0), address(this), 5 ether);
        
        // Create a limit order for token0
        ILimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(
            true,           // isToken0
            60,             // targetTick
            1 ether,        // amount
            poolKey
        );
        
        // Log position details
        bytes32 positionKey = _getPositionKey(result.bottomTick, result.topTick, result.isToken0);
        console.log("Position created with bottom tick:");
        console.log(result.bottomTick);
        console.log("top tick:");
        console.log(result.topTick);
        
        // Perform a swap that should trigger the order execution
        console.log("Executing swap to trigger order");
        BalanceDelta delta = _swap(100, false, 2 ether);
        console.log("Swap delta amount0:");
        console.log(int256(delta.amount0()));
        console.log("Swap delta amount1:");
        console.log(int256(delta.amount1()));
        
        // Check position state
        (,, bool isActive,,) = limitOrderManager.positionState(poolKey.toId(), positionKey);
        assertFalse(isActive, "Position should have been executed");
        
        // Check fees earned
        ILimitOrderManager.PositionBalances memory balances = lens.getPositionBalances(
            address(this),
            poolKey.toId(),
            positionKey
        );
        
        console.log("Fees earned token0:");
        console.log(balances.fees0);
        console.log("Fees earned token1:");
        console.log(balances.fees1);
        
        // Fees should be 0 since the fee is 0
        assertEq(balances.fees0, 0, "Fee token0 should be 0");
        assertEq(balances.fees1, 0, "Fee token1 should be 0");
        
        // Claim the order
        uint256 token0Before = currency0.balanceOf(address(this));
        uint256 token1Before = currency1.balanceOf(address(this));
        
        limitOrderManager.claimOrder(poolKey, positionKey, address(this));
        
        uint256 token0After = currency0.balanceOf(address(this));
        uint256 token1After = currency1.balanceOf(address(this));
        
        console.log("Token0 received:");
        console.log(token0After - token0Before);
        console.log("Token1 received:");
        console.log(token1After - token1Before);
    }
    
    function test_update_fee_and_execute_order() public {
        // First check the initial fee is 0
        (,,, uint24 fee) = StateLibrary.getSlot0(manager, poolKey.toId());
        console.log("Initial LP fee:");
        console.log(fee);
        assertEq(fee, 0, "Initial fee should be 0");
        
        // Update the dynamic LP fee to 400 (0.04%)
        uint24 newFee = 400;
        console.log("Updating LP fee to:");
        console.log(newFee);
        
        // Make sure we have FEE_MANAGER_ROLE
        bool hasRole = hook.hasRole(FEE_MANAGER_ROLE, address(this));
        if (!hasRole) {
            // Grant role if needed (this may vary based on hook implementation)
            vm.startPrank(address(this));
            hook.grantRole(FEE_MANAGER_ROLE, address(this));
            vm.stopPrank();
            console.log("Granted FEE_MANAGER_ROLE to test contract");
        }
        
        // Call updateDynamicLPFee
        hook.updateDynamicLPFee(poolKey, newFee);
        
        // Verify the fee was updated
        (,,, fee) = StateLibrary.getSlot0(manager, poolKey.toId());
        console.log("Updated LP fee:");
        console.log(fee);
        assertEq(fee, newFee, "Fee should be updated to 400");
        
        // Create a limit order
        deal(Currency.unwrap(currency0), address(this), 5 ether);
        
        // Create a limit order for token0
        ILimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(
            true,           // isToken0
            120,            // targetTick - different from first test
            1 ether,        // amount
            poolKey
        );
        
        // Log position details
        bytes32 positionKey = _getPositionKey(result.bottomTick, result.topTick, result.isToken0);
        console.log("Position created with bottom tick:");
        console.log(result.bottomTick);
        console.log("top tick:");
        console.log(result.topTick);
        
        // Perform a swap that should trigger the order execution
        console.log("Executing swap to trigger order");
        BalanceDelta delta = _swap(200, false, 3 ether);
        console.log("Swap delta amount0:");
        console.log(int256(delta.amount0()));
        console.log("Swap delta amount1:");
        console.log(int256(delta.amount1()));
        
        // Check position state
        (,, bool isActive,,) = limitOrderManager.positionState(poolKey.toId(), positionKey);
        assertFalse(isActive, "Position should have been executed");
        
        // Check fees earned - with fee 400, we should have non-zero fees
        ILimitOrderManager.PositionBalances memory balances = lens.getPositionBalances(
            address(this),
            poolKey.toId(),
            positionKey
        );
        
        console.log("Fees earned token0:");
        console.log(balances.fees0);
        console.log("Fees earned token1:");
        console.log(balances.fees1);
        
        // With fee of 400 (0.04%), fees should be non-zero after swap
        assertTrue(balances.fees0 > 0 || balances.fees1 > 0, "Fees should be non-zero with fee 400");
        
        // Claim the order
        uint256 token0Before = currency0.balanceOf(address(this));
        uint256 token1Before = currency1.balanceOf(address(this));
        
        limitOrderManager.claimOrder(poolKey, positionKey, address(this));
        
        uint256 token0After = currency0.balanceOf(address(this));
        uint256 token1After = currency1.balanceOf(address(this));
        
        console.log("Token0 received:");
        console.log(token0After - token0Before);
        console.log("Token1 received:");
        console.log(token1After - token1Before);
    }
    
    function test_fee_manager_role_access_control() public {
        // Because we're testing role-based access control in isolation:
        // 1. First directly grant ourselves access in the hook
        // 2. This mimics setup but avoids dependency on LimitOrderManager initialization logic
        
        // Since we can modify the contract state in the test, we'll do this forcefully
        vm.store(
            address(hook),
            keccak256(abi.encode(address(this), uint256(DEFAULT_ADMIN_ROLE))),
            bytes32(uint256(1))
        );
        
        // Verify we now have admin permissions
        assertTrue(hook.hasRole(DEFAULT_ADMIN_ROLE, address(this)), "Test contract should have admin role");
        
        // Grant ourselves the fee manager role
        hook.grantRole(FEE_MANAGER_ROLE, address(this));
        
        // Now update fees with proper permissions - this should succeed
        hook.updateDynamicLPFee(poolKey, 100);
        
        // Try with random address that doesn't have permission
        address randomAddr = makeAddr("randomAddress");
        vm.startPrank(randomAddr);
        vm.expectRevert();  // Using just expectRevert() to catch any revert
        hook.updateDynamicLPFee(poolKey, 100);
        vm.stopPrank();
    }

    function test_comprehensive_role_management() public {
        // Set up test contract as admin using VM storage manipulation
        vm.store(
            address(hook),
            keccak256(abi.encode(address(this), uint256(DEFAULT_ADMIN_ROLE))),
            bytes32(uint256(1))
        );
        
        // Create new address for fee manager
        address newFeeManager = makeAddr("newFeeManager");
        // Create new address for admin
        address newAdmin = makeAddr("newAdmin");
        // Create random address without any roles
        address randomAddr = makeAddr("randomAddress");
        
        // Random address should not be able to update fees
        vm.startPrank(randomAddr);
        vm.expectRevert();
        hook.updateDynamicLPFee(poolKey, 100);
        vm.stopPrank();
        
        // Random address should not be able to grant roles
        vm.startPrank(randomAddr);
        vm.expectRevert();
        hook.grantRole(FEE_MANAGER_ROLE, newFeeManager);
        vm.stopPrank();
        
        // Test contract (now admin) should be able to grant FEE_MANAGER_ROLE to newFeeManager
        hook.grantRole(FEE_MANAGER_ROLE, newFeeManager);
        hook.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        
        // New fee manager should be able to update fees
        vm.startPrank(newFeeManager);
        hook.updateDynamicLPFee(poolKey, 150);
        vm.stopPrank();
        
        // New admin should be able to grant FEE_MANAGER_ROLE to randomAddr
        vm.startPrank(newAdmin);
        hook.grantRole(FEE_MANAGER_ROLE, randomAddr);
        vm.stopPrank();
        
        // Random address (now with FEE_MANAGER_ROLE) should be able to update fees
        vm.startPrank(randomAddr);
        hook.updateDynamicLPFee(poolKey, 200);
        vm.stopPrank();
    }

    function test_role_management_functions() public {
        // Set up test contract as admin using VM storage manipulation
        vm.store(
            address(hook),
            keccak256(abi.encode(address(this), uint256(DEFAULT_ADMIN_ROLE))),
            bytes32(uint256(1))
        );
        
        // Create test addresses
        address newFeeManager = makeAddr("newFeeManager");
        address secondFeeManager = makeAddr("secondFeeManager");
        
        // Initially, only test contract should have DEFAULT_ADMIN_ROLE
        assertTrue(hook.hasRole(DEFAULT_ADMIN_ROLE, address(this)), "Test contract should have admin role");
        assertFalse(hook.hasRole(DEFAULT_ADMIN_ROLE, newFeeManager), "newFeeManager should not have admin role");
        
        // No one should have FEE_MANAGER_ROLE yet
        assertFalse(hook.hasRole(FEE_MANAGER_ROLE, newFeeManager), "newFeeManager should not have role yet");
        assertFalse(hook.hasRole(FEE_MANAGER_ROLE, secondFeeManager), "secondFeeManager should not have role yet");
        
        // Test contract grants FEE_MANAGER_ROLE to managers
        hook.grantRole(FEE_MANAGER_ROLE, newFeeManager);
        hook.grantRole(FEE_MANAGER_ROLE, secondFeeManager);
        
        // Verify roles were granted correctly
        assertTrue(hook.hasRole(FEE_MANAGER_ROLE, newFeeManager), "newFeeManager should have fee manager role");
        assertTrue(hook.hasRole(FEE_MANAGER_ROLE, secondFeeManager), "secondFeeManager should have fee manager role");
        
        // Test contract revokes role from secondFeeManager
        hook.revokeRole(FEE_MANAGER_ROLE, secondFeeManager);
        
        // Verify role was revoked
        assertFalse(hook.hasRole(FEE_MANAGER_ROLE, secondFeeManager), "secondFeeManager should no longer have fee manager role");
        
        // Verify secondFeeManager can no longer update fees
        vm.startPrank(secondFeeManager);
        vm.expectRevert();
        hook.updateDynamicLPFee(poolKey, 100);
        vm.stopPrank();
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
}

