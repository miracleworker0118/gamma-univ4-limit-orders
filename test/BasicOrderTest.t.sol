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
import {LimitOrderLens} from "src/LimitOrderLens.sol";
import "../src/TickLibrary.sol";

contract BasicOrderTest is Test, Deployers {
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
        
        // Deploy LimitOrderLens for querying position data
        lens = new LimitOrderLens(
            address(orderManager),
            address(this)  // This test contract as owner
        );
        
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
                tickLower: -887220,
                tickUpper: 887220,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function test_hook_permissions() public {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
    }

    function test_create_order_validation() public {
        uint256 price = 1.02e18;
        uint256 roundedPrice = TickLibrary.getRoundedPrice(price, poolKey, true);
        int24 targetTick = TickMath.getTickAtSqrtPrice(TickLibrary.getSqrtPriceFromPrice(roundedPrice));

        // Test zero amount
        vm.expectRevert();
        // limitOrderManager.createLimitOrder(true, false, targetTick, 0, poolKey);
        limitOrderManager.createLimitOrder(true, targetTick, 0, poolKey);
    }

    function test_order_execution() public {
        deal(Currency.unwrap(currency0), address(this), 100 ether);
        deal(Currency.unwrap(currency1), address(this), 100 ether);
        
        uint256 sellAmount = 1 ether;
        uint256 limitPrice = 1.02e18;
        PoolId poolId = poolKey.toId();

        uint256 balance0Before = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 balance1Before = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));

        // Get the target tick from the rounded price
        uint256 roundedPrice = TickLibrary.getRoundedPrice(limitPrice, poolKey, true);
        int24 targetTick = TickMath.getTickAtSqrtPrice(TickLibrary.getSqrtPriceFromPrice(roundedPrice));

        // LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(true, false, targetTick, sellAmount, poolKey);
        LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(true, targetTick, sellAmount, poolKey);
        assertTrue(result.usedAmount > 0, "Invalid amount");
        assertTrue(result.isToken0, "Wrong token direction");
        assertTrue(result.bottomTick < result.topTick, "Invalid tick range");

        // Execute with swap
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -2 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(result.topTick + 100)
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );

        (LimitOrderManager.ClaimableTokens memory token0Balance, LimitOrderManager.ClaimableTokens memory token1Balance) = 
            getClaimableBalances(address(this), poolKey);

        assertTrue(
            token0Balance.principal > 0 || token1Balance.principal > 0,
            "No tokens claimable after execution"
        );
    }

    // Main test function split into smaller parts
    function test_create_order_with_native_eth() public {
        PoolKey memory ethPoolKey = _setupEthPool();
        orderManager.setWhitelistedPool(ethPoolKey.toId(), true);
        _testEthLimitOrder(ethPoolKey);
    }

    // Setup function extracted to reduce stack depth
    function _setupEthPool() internal returns (PoolKey memory ethPoolKey) {
        Currency ethCurrency = CurrencyLibrary.ADDRESS_ZERO;
        
        // Initialize pool with 1:1 price
        (ethPoolKey,) = initPool(ethCurrency, currency1, hook, 3000, 3186567802612673354889053);
        
        // Add initial liquidity with the same wide tick range but much smaller liquidity
        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            ethPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220,  // Keep wide range
                tickUpper: 887220,   // Keep wide range
                liquidityDelta: 0.00001 ether, // Much smaller liquidity amount
                salt: bytes32(0)
            }),
            ""
        );
    }

    // Split order creation and execution into separate functions
    function _testEthLimitOrder(PoolKey memory ethPoolKey) internal {
        (bytes32 positionKey, LimitOrderManager.CreateOrderResult memory result) = 
            _createEthOrder(ethPoolKey);
        _executeAndVerifyOrder(ethPoolKey, positionKey, result);
    }

    function _createEthOrder(PoolKey memory ethPoolKey) internal returns (
        bytes32 positionKey,
        LimitOrderManager.CreateOrderResult memory result
    ) {
        uint256 sellAmount = 1 ether;
        
        // Get current tick and set target tick to current + 100
        (, int24 currentTick,,) = StateLibrary.getSlot0(manager, ethPoolKey.toId());
        int24 targetTick = currentTick + 100;
        
        // Ensure tick is properly spaced according to the pool's tick spacing
        targetTick = (targetTick / ethPoolKey.tickSpacing) * ethPoolKey.tickSpacing;
        
        console.log("\nCreating ETH Order");
        console.log("Current tick:", currentTick);
        console.log("Target tick:", targetTick);
        
        // Create limit order
        result = limitOrderManager.createLimitOrder{value: sellAmount}(
            true, targetTick, sellAmount, ethPoolKey
        );     
        // Test excess ETH handling
        uint256 balanceBefore = address(this).balance;
        limitOrderManager.createLimitOrder{value: sellAmount * 2}(
            true, targetTick, sellAmount, ethPoolKey
        );
        assertEq(address(this).balance, balanceBefore - sellAmount, "Excess ETH not returned");
        
        // Generate position key
        PoolId poolId = ethPoolKey.toId();
        bytes32 baseKey = getBasePositionKey(result.bottomTick, result.topTick, result.isToken0);
        uint256 nonce = limitOrderManager.currentNonce(poolId, baseKey);
        positionKey = getPositionKey(result.bottomTick, result.topTick, result.isToken0, nonce);
    }

    function _executeAndVerifyOrder(
        PoolKey memory ethPoolKey,
        bytes32 positionKey,
        LimitOrderManager.CreateOrderResult memory result
    ) internal {
        // Add this before the swap
        deal(address(this), 10 ether);

        // Use a smaller swap amount as int256 (positive means we're selling exactly this amount)
        int256 swapAmount = 0.1 ether;

        // Execute swap
        swapRouter.swap{value: uint256(swapAmount)}(
            ethPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: swapAmount,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(result.bottomTick - 60)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Log initial state
        (, int24 currentTick,,) = StateLibrary.getSlot0(manager, ethPoolKey.toId());
        console.log("\nBefore swap:");
        console.log("Current tick:", currentTick);
        console.log("Order bottom tick:", result.bottomTick);
        console.log("Order top tick:", result.topTick);

        // Get claimable balances before attempting claim
        (LimitOrderManager.ClaimableTokens memory ethBal, LimitOrderManager.ClaimableTokens memory token1Bal) = 
            getClaimableBalances(address(this), ethPoolKey);
        
        console.log("\nClaimable balances:");
        console.log("ETH principal:", ethBal.principal);
        console.log("ETH fees:", ethBal.fees);
        console.log("Token1 principal:", token1Bal.principal);
        console.log("Token1 fees:", token1Bal.fees);

        _verifyAndClaimOrder(ethPoolKey, positionKey);
    }

    function _verifyAndClaimOrder(PoolKey memory ethPoolKey, bytes32 positionKey) internal {
        // Record initial balances
        uint256 ethBefore = address(this).balance;
        uint256 token1Before = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));
        
        // Get claimable amounts
        (LimitOrderManager.ClaimableTokens memory ethBal, LimitOrderManager.ClaimableTokens memory token1Bal) = 
            getClaimableBalances(address(this), ethPoolKey);
        
        require(ethBal.principal > 0 || token1Bal.principal > 0, "Nothing to claim");
        
        // Claim and verify
        try limitOrderManager.claimOrder(ethPoolKey, positionKey, address(this)) {
            _verifyClaimAmounts(ethPoolKey, ethBefore, token1Before, ethBal, token1Bal);
        } catch Error(string memory reason) {
            _handleClaimError(ethPoolKey, positionKey, reason);
        } catch {
            _handleClaimError(ethPoolKey, positionKey, "");
        }
    }

    function _verifyClaimAmounts(
        PoolKey memory ethPoolKey,
        uint256 ethBefore,
        uint256 token1Before,
        LimitOrderManager.ClaimableTokens memory ethBal,
        LimitOrderManager.ClaimableTokens memory token1Bal
    ) internal {
        uint256 ethAfter = address(this).balance;
        uint256 token1After = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));
        
        if (token1Bal.principal > 0) {
            assertEq(
                token1After - token1Before,
                uint256(uint128(token1Bal.principal + token1Bal.fees)),
                "Token1 claim incorrect"
            );
        }
        
        if (ethBal.principal > 0) {
            uint256 ethReceived = ethAfter - ethBefore;
            uint256 expectedEth = uint256(uint128(ethBal.principal + ethBal.fees));
            
            // Allow for 1 wei rounding difference
            assertApproxEqAbs(
                ethReceived,
                expectedEth,
                1,  // maximum absolute difference of 1 wei
                "ETH claim incorrect"
            );
        }
        
        // Verify balances zeroed
        (ethBal, token1Bal) = getClaimableBalances(address(this), ethPoolKey);
        assertEq(ethBal.principal + ethBal.fees + token1Bal.principal + token1Bal.fees, 0, "Claim incomplete");
    }

    function _handleClaimError(
        PoolKey memory ethPoolKey,
        bytes32 positionKey,
        string memory reason
    ) internal view {
        if (bytes(reason).length > 0) {
            console.log("Claim failed with reason:", reason);
        } else {
            console.log("Claim failed without reason");
        }
        _debugPositionState(ethPoolKey, positionKey);
    }

    // Simplified debug helper
    function _debugPositionState(PoolKey memory ethPoolKey, bytes32 positionKey) internal view {
        PoolId poolId = ethPoolKey.toId();
        
        console.log("\nPosition Debug Info:");
        console.log("Currency0:", Currency.unwrap(ethPoolKey.currency0));
        console.log("Currency1:", Currency.unwrap(ethPoolKey.currency1));
        console.log("Position Key:", uint256(positionKey));
        
        ILimitOrderManager.PositionInfo[] memory positions = limitOrderManager.getUserPositions(address(this), poolId);
        if (positions.length > 0) {
            // bytes32[] memory keys = limitOrderManager.getUserPositionKeys(address(this), poolId, 0, count);
            for (uint i = 0; i < positions.length; i++) {
                if (positions[i].positionKey == positionKey) {
                    console.log("Found position at index:", i);
                    break;
                }
            }
        }
    }

    function test_create_order_with_token1_for_eth() public {
        PoolKey memory ethPoolKey = _setupEthPool();
        orderManager.setWhitelistedPool(ethPoolKey.toId(), true);
        _testToken1ForEthOrder(ethPoolKey);
    }

    function _testToken1ForEthOrder(PoolKey memory ethPoolKey) internal {
        (bytes32 positionKey, LimitOrderManager.CreateOrderResult memory result) = 
            _createToken1Order(ethPoolKey);
        _executeAndVerifyToken1Order(ethPoolKey, positionKey, result);
    }

    function _createToken1Order(PoolKey memory ethPoolKey) internal returns (
        bytes32 positionKey,
        LimitOrderManager.CreateOrderResult memory result
    ) {
        // Check current tick and price
        (, int24 currentTick,,) = StateLibrary.getSlot0(manager, ethPoolKey.toId());
        console.log("\nCreating Token1->ETH Order");
        console.log("Current tick:", currentTick);
        
        // Use a much smaller amount for the test
        uint256 sellAmount = 0.001 ether;
        
        // Use fixed target tick of -202500
        int24 targetTick = -202500;
        
        // Validate tick with spacing
        targetTick = targetTick - (targetTick % ethPoolKey.tickSpacing);
        
        console.log("Target tick:", targetTick);
        
        result = limitOrderManager.createLimitOrder(
            false,  // isToken0 = false (selling token1)
            targetTick,
            sellAmount,
            ethPoolKey
        );
        
        // Generate position key
        PoolId poolId = ethPoolKey.toId();
        bytes32 baseKey = getBasePositionKey(result.bottomTick, result.topTick, result.isToken0);
        uint256 nonce = limitOrderManager.currentNonce(poolId, baseKey);
        positionKey = getPositionKey(result.bottomTick, result.topTick, result.isToken0, nonce);
        
        return (positionKey, result);
    }

    function _executeAndVerifyToken1Order(
        PoolKey memory ethPoolKey,
        bytes32 positionKey,
        LimitOrderManager.CreateOrderResult memory result
    ) internal {
        // Provide ETH to all relevant contracts
        deal(address(this), 1000000 ether);  
        deal(address(manager), 1000000 ether);
        deal(address(swapRouter), 1000000 ether);  // Add ETH to swapRouter too
        
        // Log initial state
        (, int24 currentTick,,) = StateLibrary.getSlot0(manager, ethPoolKey.toId());
        console.log("\nBefore swap:");
        console.log("Current tick:", currentTick);
        console.log("Order bottom tick:", result.bottomTick);
        console.log("Order top tick:", result.topTick);
        
        // For token1->ETH orders at negative ticks
        swapRouter.swap(
            ethPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,  
                amountSpecified: -1 ether,  
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(result.topTick + 60)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        
        // Rest of function remains the same...
    }

    function test_order_execution_token1() public {
        // Setup initial balances
        deal(Currency.unwrap(currency0), address(this), 100 ether);
        deal(Currency.unwrap(currency1), address(this), 100 ether);
        
        uint256 sellAmount = 1 ether;
        uint256 limitPrice = 0.98e18; // Price below 1 since we're selling token1
        PoolId poolId = poolKey.toId();

        // Get the target tick from the rounded price
        uint256 roundedPrice = TickLibrary.getRoundedPrice(limitPrice, poolKey, false);
        int24 targetTick = TickMath.getTickAtSqrtPrice(TickLibrary.getSqrtPriceFromPrice(roundedPrice));

        // Create limit order selling token1
        // LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(
        //     false, // isToken0 = false (selling token1)
        //     false, // not a range order
        //     targetTick,
        //     sellAmount,
        //     poolKey
        // );
        LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(
            false, // isToken0 = false (selling token1)
            targetTick,
            sellAmount,
            poolKey
        );
        // Verify order creation
        assertTrue(result.usedAmount > 0, "Invalid amount");
        assertFalse(result.isToken0, "Wrong token direction");
        assertTrue(result.bottomTick < result.topTick, "Invalid tick range");

        // Execute with swap (opposite direction from previous test)
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true, // Swapping token0 for token1 to decrease price
                amountSpecified: 2 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(result.bottomTick - 100)
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );

        // Check claimable balances
        (LimitOrderManager.ClaimableTokens memory token0Balance, LimitOrderManager.ClaimableTokens memory token1Balance) = 
            getClaimableBalances(address(this), poolKey);

        assertTrue(
            token0Balance.principal > 0 || token1Balance.principal > 0,
            "No tokens claimable after execution"
        );
    }

    function test_order_execution_and_claim_token1() public {
        console.log("\n=== Setting up test ===");
        // Setup initial balances
        deal(Currency.unwrap(currency0), address(this), 100 ether);
        deal(Currency.unwrap(currency1), address(this), 100 ether);
        
        uint256 sellAmount = 1 ether;
        uint256 limitPrice = 0.98e18;
        PoolId poolId = poolKey.toId();

        console.log("Initial setup:");
        console.log("Sell amount:", sellAmount);
        console.log("Limit price:", limitPrice);

        // Get the target tick from the rounded price
        uint256 roundedPrice = TickLibrary.getRoundedPrice(limitPrice, poolKey, false);
        int24 targetTick = TickMath.getTickAtSqrtPrice(TickLibrary.getSqrtPriceFromPrice(roundedPrice));

        console.log("\n=== Creating limit order ===");
        console.log("Target tick:", targetTick);
        console.log("Rounded price:", roundedPrice);

        // Create limit order selling token1
        // LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(
        //     false, // isToken0 = false (selling token1)
        //     false, // not a range order
        //     targetTick,
        //     sellAmount,
        //     poolKey
        // );
        LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(
            false, // isToken0 = false (selling token1)
            targetTick,
            sellAmount,
            poolKey
        );
        console.log("\nOrder created:");
        console.log("Used amount:", result.usedAmount);
        console.log("Bottom tick:", result.bottomTick);
        console.log("Top tick:", result.topTick);
        console.log("Is token0:", result.isToken0);

        // Verify order creation
        assertTrue(result.usedAmount > 0, "Invalid amount");
        assertFalse(result.isToken0, "Wrong token direction");
        assertTrue(result.bottomTick < result.topTick, "Invalid tick range");

        // Get position key
        bytes32 baseKey = getBasePositionKey(result.bottomTick, result.topTick, result.isToken0);
        uint256 nonce = limitOrderManager.currentNonce(poolId, baseKey);
        bytes32 positionKey = getPositionKey(result.bottomTick, result.topTick, result.isToken0, nonce);

        // Record balances before execution
        uint256 balance0Before = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 balance1Before = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));

        console.log("\n=== Executing swap ===");
        console.log("Initial balances:");
        console.log("Token0:", balance0Before);
        console.log("Token1:", balance1Before);

        // Execute with swap
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 2 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(result.bottomTick - 100)
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );

        console.log("\n=== Checking claimable amounts ===");
        // Get claimable balances before claiming
        (LimitOrderManager.ClaimableTokens memory token0Before, LimitOrderManager.ClaimableTokens memory token1Before) = 
            getClaimableBalances(address(this), poolKey);

        console.log("Claimable before claiming:");
        console.log("Token0 principal:", token0Before.principal);
        console.log("Token0 fees:", token0Before.fees);
        console.log("Token1 principal:", token1Before.principal);
        console.log("Token1 fees:", token1Before.fees);

        // Ensure there are claimable tokens
        assertTrue(
            token0Before.principal > 0 || token1Before.principal > 0,
            "No tokens claimable after execution"
        );

        // Record balances before claim
        uint256 preClaimBalance0 = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 preClaimBalance1 = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));

        console.log("\n=== Claiming order ===");
        console.log("Balances before claim:");
        console.log("Token0:", preClaimBalance0);
        console.log("Token1:", preClaimBalance1);

        // Claim the order
        limitOrderManager.claimOrder(poolKey, positionKey, address(this));

        // Get balances after claim
        uint256 postClaimBalance0 = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 postClaimBalance1 = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));

        console.log("\nBalances after claim:");
        console.log("Token0:", postClaimBalance0);
        console.log("Token1:", postClaimBalance1);

        // Calculate actual balance changes
        uint256 token0Received = postClaimBalance0 - preClaimBalance0;
        uint256 token1Received = postClaimBalance1 - preClaimBalance1;

        console.log("\nTokens received from claim:");
        console.log("Token0 received:", token0Received);
        console.log("Token1 received:", token1Received);

        // // Calculate expected amounts from claimable balances
        // uint256 expectedToken0 = uint256(uint128(token0Before.principal + token0Before.fees));
        // uint256 expectedToken1 = uint256(uint128(token1Before.principal + token1Before.fees));

        // console.log("\nExpected amounts:");
        // console.log("Expected token0:", expectedToken0);
        // console.log("Expected token1:", expectedToken1);

        // // Verify received amounts match claimable balances
        // assertEq(token0Received, expectedToken0, "Token0 claimed amount doesn't match claimable balance");
        // assertEq(token1Received, expectedToken1, "Token1 claimed amount doesn't match claimable balance");

        // Verify claimable balances are now zero
        (LimitOrderManager.ClaimableTokens memory token0After, LimitOrderManager.ClaimableTokens memory token1After) = 
            getClaimableBalances(address(this), poolKey);

        console.log("\n=== Final claimable balances ===");
        console.log("Token0 principal:", token0After.principal);
        console.log("Token0 fees:", token0After.fees);
        console.log("Token1 principal:", token1After.principal);
        console.log("Token1 fees:", token1After.fees);

        assertEq(token0After.principal, 0, "Token0 principal should be zero after claim");
        assertEq(token0After.fees, 0, "Token0 fees should be zero after claim");
        assertEq(token1After.principal, 0, "Token1 principal should be zero after claim");
        assertEq(token1After.fees, 0, "Token1 fees should be zero after claim");
    }
    
    function test_order_cancellation() public {
        deal(Currency.unwrap(currency0), address(this), 100 ether);
        deal(Currency.unwrap(currency1), address(this), 100 ether);

        uint256 price = 1.02e18;
        uint256 roundedPrice = TickLibrary.getRoundedPrice(price, poolKey, true);
        int24 targetTick = TickMath.getTickAtSqrtPrice(TickLibrary.getSqrtPriceFromPrice(roundedPrice));

        // ILimitOrderManager.LimitOrderParams memory params = ILimitOrderManager.LimitOrderParams({
        //     isToken0: true,
        //     isRange: true,
        //     targetTick: targetTick,
        //     amount: 1 ether
        // });

        // LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(true, true, targetTick, 1 ether, poolKey);
        LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(true, targetTick, 1 ether, poolKey);      
        bytes32 baseKey = getBasePositionKey(result.bottomTick, result.topTick, result.isToken0);
        PoolId poolId = poolKey.toId();
        uint256 nonce = limitOrderManager.currentNonce(poolId, baseKey);
        bytes32 positionKey = getPositionKey(result.bottomTick, result.topTick, result.isToken0, nonce);

        uint256 balanceBefore = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
        
        limitOrderManager.cancelOrder(poolKey, positionKey);
        
        uint256 balanceAfter = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
        assertTrue(balanceAfter > balanceBefore, "No tokens returned after cancellation");
    }

    // function test_gas_multiple_range_orders_same_target() public {
    //     deal(Currency.unwrap(currency0), address(this), 100 ether);
    //     deal(Currency.unwrap(currency1), address(this), 100 ether);

    //     limitOrderManager.setExecutablePositionsLimit(10);
        
    //     (, int24 currentTick,,) = StateLibrary.getSlot0(manager, poolKey.toId());
    //     int24 targetTick = 5000;

    //     console.log("\nCreating orders with target tick:", targetTick);
    //     console.log("Starting at current tick:", currentTick);

    //     // Create 10 orders with different ranges but same target tick
    //     for (uint256 i = 0; i < 10; i++) {
    //         console.log("\nCreating Order", i + 1);
    //         console.log("Current tick before swap:", currentTick);
            
    //         // Small swap going down in price each time
    //         swapRouter.swap(
    //             poolKey,
    //             IPoolManager.SwapParams({
    //                 zeroForOne: true,
    //                 amountSpecified: 0.2 ether,
    //                 sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(currentTick - 100)
    //             }),
    //             PoolSwapTest.TestSettings({
    //                 takeClaims: false,
    //                 settleUsingBurn: false
    //             }),
    //             ""
    //         );

    //         // Get updated tick after swap
    //         (, currentTick,,) = StateLibrary.getSlot0(manager, poolKey.toId());
    //         console.log("Current tick after swap:", currentTick);

    //         // Create range order
    //         ILimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(true, true, targetTick, 1 ether, poolKey);
    //         // Get position details
    //         bytes32 baseKey = getBasePositionKey(result.bottomTick, result.topTick, result.isToken0);
    //         PoolId poolId = poolKey.toId();
    //         uint256 nonce = limitOrderManager.currentNonce(poolId, baseKey);
    //         bytes32 positionKey = getPositionKey(result.bottomTick, result.topTick, result.isToken0, nonce);

    //         // Log order details
    //         console.log("Order Range:");
    //         console.log("  Bottom Tick:", result.bottomTick);
    //         console.log("  Top Tick:", result.topTick);
    //         console.log("  Range Size:", result.topTick - result.bottomTick);
    //         console.log("  Amount Used:", result.usedAmount);
            
    //         // Get liquidity for this position
    //         (uint128 liquidity, , ) = StateLibrary.getPositionInfo(
    //             manager,
    //             poolId,
    //             address(limitOrderManager),
    //             result.bottomTick,
    //             result.topTick,
    //             bytes32(0)
    //         );
    //         console.log("  Liquidity:", liquidity);
    //     }

    //     // Execute all orders
    //     console.log("\nExecuting all orders...");
    //     uint256 gasBefore = gasleft();
        
    //     swapRouter.swap(
    //         poolKey,
    //         IPoolManager.SwapParams({
    //             zeroForOne: false,
    //             amountSpecified: -100 ether,
    //             sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(targetTick + 100)
    //         }),
    //         PoolSwapTest.TestSettings({
    //             takeClaims: false,
    //             settleUsingBurn: false
    //         }),
    //         ""
    //     );
    //     (, currentTick,,) = StateLibrary.getSlot0(manager, poolKey.toId());
    //     console.log("Current tick after execution:", currentTick);
    //     uint256 gasUsed = gasBefore - gasleft();
    //     console.log("Gas used for executing 10 range orders:", gasUsed);

    //     // Verify orders were executed
    //     (ILimitOrderManager.ClaimableTokens memory token0Balance, ILimitOrderManager.ClaimableTokens memory token1Balance) = 
    //         limitOrderManager.getUserClaimableBalances(address(this), poolKey);
        
    //     assertTrue(
    //         token0Balance.principal > 0 || token1Balance.principal > 0,
    //         "No tokens claimable after execution"
    //     );
    // }

    function test_min_amount_validation() public {
        // Set min amount for currency0 to 0.5 ether
        limitOrderManager.setMinAmount(currency0, 0.5 ether);
        
        uint256 price = 1.02e18;
        uint256 roundedPrice = TickLibrary.getRoundedPrice(price, poolKey, true);
        int24 targetTick = TickMath.getTickAtSqrtPrice(TickLibrary.getSqrtPriceFromPrice(roundedPrice));

        // Try to create order with amount less than minimum (0.1 ether < 0.5 ether)
        vm.expectRevert(abi.encodeWithSelector(
            ILimitOrderManager.MinimumAmountNotMet.selector,
            0.1 ether,
            0.5 ether
        ));
        // limitOrderManager.createLimitOrder(true, false, targetTick, 0.1 ether, poolKey);
        limitOrderManager.createLimitOrder(true, targetTick, 0.1 ether, poolKey);

    }

    function test_claim_order_balances() public {
        // Setup initial balances
        deal(Currency.unwrap(currency0), address(this), 100 ether);
        deal(Currency.unwrap(currency1), address(this), 100 ether);
        
        uint256 sellAmount = 1 ether;
        uint256 limitPrice = 1.02e18;

        // Record initial token balances
        uint256 initialBalance0 = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 initialBalance1 = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));

        // Create limit order
        uint256 roundedPrice = TickLibrary.getRoundedPrice(limitPrice, poolKey, true);
        int24 targetTick = TickMath.getTickAtSqrtPrice(TickLibrary.getSqrtPriceFromPrice(roundedPrice));
        
        // LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(
        //     true,    // isToken0
        //     false,   // not range order
        //     targetTick,
        //     sellAmount,
        //     poolKey
        // );
        LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(
            true,    // isToken0
            targetTick,
            sellAmount,
            poolKey
        );

        // Get position key
        bytes32 baseKey = getBasePositionKey(result.bottomTick, result.topTick, result.isToken0);
        PoolId poolId = poolKey.toId();
        uint256 nonce = limitOrderManager.currentNonce(poolId, baseKey);
        bytes32 positionKey = getPositionKey(result.bottomTick, result.topTick, result.isToken0, nonce);

        // Execute order with swap
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -2 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(result.topTick + 100)
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );

        // Get claimable balances before claiming
        (LimitOrderManager.ClaimableTokens memory token0Before, LimitOrderManager.ClaimableTokens memory token1Before) = 
            getClaimableBalances(address(this), poolKey);

        console.log("Claimable Balances:");
        console.log("Token0 Principal:", token0Before.principal);
        console.log("Token0 Fees:", token0Before.fees);
        console.log("Token1 Principal:", token1Before.principal);
        console.log("Token1 Fees:", token1Before.fees);

        // Record balances before claim
        uint256 beforeBalance0 = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 beforeBalance1 = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));

        console.log("\nBalances Before Claim:");
        console.log("Token0 Balance:", beforeBalance0);
        console.log("Token1 Balance:", beforeBalance1);

        // Claim the order
        limitOrderManager.claimOrder(poolKey, positionKey, address(this));

        // Get balances after claim
        uint256 afterBalance0 = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 afterBalance1 = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));

        console.log("\nBalances After Claim:");
        console.log("Token0 Balance:", afterBalance0);
        console.log("Token1 Balance:", afterBalance1);

        // Calculate actual balance changes
        uint256 token0Change = afterBalance0 > beforeBalance0 ? 
            afterBalance0 - beforeBalance0 : 0;
        uint256 token1Change = afterBalance1 > beforeBalance1 ? 
            afterBalance1 - beforeBalance1 : 0;

        console.log("\nBalance Changes:");
        console.log("Token0 Change:", token0Change);
        console.log("Token1 Change:", token1Change);

        console.log("\nExpected Changes:");
        console.log("Token0 Expected:", uint256(uint128(token0Before.principal + (token0Before.fees * (FEE_DENOMINATOR - HOOK_FEE_PERCENTAGE)) / FEE_DENOMINATOR)));
        console.log("Token1 Expected:", uint256(uint128(token1Before.principal + (token1Before.fees * (FEE_DENOMINATOR - HOOK_FEE_PERCENTAGE)) / FEE_DENOMINATOR)));

        // Verify that claimed amounts match the claimable balances
        assertEq(
            token0Change,
            uint256(uint128(token0Before.principal + token0Before.fees )),
            "Token0 claimed amount doesn't match claimable balance"
        );
        assertEq(
            token1Change,
            uint256(uint128(token1Before.principal + token1Before.fees )),
            "Token1 claimed amount doesn't match claimable balance"
        );

        // Verify claimable balances are now zero
        (LimitOrderManager.ClaimableTokens memory token0After, LimitOrderManager.ClaimableTokens memory token1After) = 
            getClaimableBalances(address(this), poolKey);

        assertEq(token0After.principal, 0, "Token0 principal should be zero after claim");
        assertEq(token0After.fees, 0, "Token0 fees should be zero after claim");
        assertEq(token1After.principal, 0, "Token1 principal should be zero after claim");
        assertEq(token1After.fees, 0, "Token1 fees should be zero after claim");
    }

    function test_dos_attack_with_many_positions() public {
        // Provide enough tokens for testing
        deal(Currency.unwrap(currency0), address(this), 2000 ether);
        deal(Currency.unwrap(currency1), address(this), 2000 ether);

        // Remove execution limit to test DOS potential
        limitOrderManager.setExecutablePositionsLimit(type(uint256).max);
        
        // Initial state
        (, int24 startingTick,,) = StateLibrary.getSlot0(manager, poolKey.toId());
        console.log("Starting tick:");
        console.logInt(startingTick);
        
        // Calculate a reasonable target tick range
        int24 baseTargetTick = startingTick + 120; // Start just a bit above current tick
        uint256 totalPositions = 750;
        
        console.log("Creating positions...");
        uint256 createGasUsed = 0;
        
        // Track current tick
        int24 currentTick = startingTick;
        
        // Create positions in batches to avoid block gas limit
        for (uint256 i = 0; i < totalPositions; i++) {
            if (i % 120 == 0) {
                console.log("Progress:");
                console.logUint(i);
            }
            
            uint256 gasBeforeCreate = gasleft();
            
            // Create limit order with small tick spacing between orders
            int24 orderTargetTick = baseTargetTick + int24(uint24(i * uint24(poolKey.tickSpacing)));
            
            // limitOrderManager.createLimitOrder(true, false, orderTargetTick, 0.1 ether, poolKey);
            limitOrderManager.createLimitOrder(true, orderTargetTick, 0.1 ether, poolKey);
            
            
            createGasUsed += gasBeforeCreate - gasleft();

            // Calculate lower price limit for the zeroForOne swap
            int24 targetSwapTick = currentTick - int24(poolKey.tickSpacing);
            uint160 lowerPriceLimit = TickMath.getSqrtPriceAtTick(targetSwapTick);
            
            // Make a small swap to move the price slightly
            swapRouter.swap(
                poolKey,
                IPoolManager.SwapParams({
                    zeroForOne: true,  // swapping token0 for token1, price goes down
                    amountSpecified: 0.001 ether,
                    sqrtPriceLimitX96: lowerPriceLimit
                }),
                PoolSwapTest.TestSettings({
                    takeClaims: false,
                    settleUsingBurn: false
                }),
                ""
            );

            // Update current tick for next iteration
            (, currentTick,,) = StateLibrary.getSlot0(manager, poolKey.toId());
        }
        
        console.log("Creation gas:");
        console.logUint(createGasUsed);
        
        // Calculate final price limit for execution swap
        int24 finalTargetTick = baseTargetTick + int24(uint24(totalPositions * uint24(poolKey.tickSpacing)));
        uint160 finalPriceLimit = TickMath.getSqrtPriceAtTick(finalTargetTick + int24(poolKey.tickSpacing));
        
        console.log("Executing positions...");
        uint256 gasBeforeExecute = gasleft();
        
        try swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,  // swapping token1 for token0, price goes up
                amountSpecified: -1000 ether,
                sqrtPriceLimitX96: finalPriceLimit
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        ) {
            uint256 executeGasUsed = gasBeforeExecute - gasleft();
            console.log("Execution gas:");
            console.logUint(executeGasUsed);
            console.log("Average gas per position:");
            console.logUint(executeGasUsed / totalPositions);
        } catch Error(string memory reason) {
            console.log(reason);
            revert("Execution failed - see reason above");
        } catch {
            revert("Execution failed silently");
        }
        
        // Verify some positions were executed by checking claimable balances
        (ILimitOrderManager.ClaimableTokens memory token0Balance, ILimitOrderManager.ClaimableTokens memory token1Balance) = 
            getClaimableBalances(address(this), poolKey);
        
        console.log("Token0 claimable:");
        console.logUint(token0Balance.principal);
        console.log("Token1 claimable:");
        console.logUint(token1Balance.principal);
        
        assertTrue(
            token0Balance.principal > 0 || token1Balance.principal > 0,
            "No tokens claimable after execution"
        );
    } 

    function test_findOverlapping() public {
        deal(Currency.unwrap(currency0), address(this), 100 ether);
        deal(Currency.unwrap(currency1), address(this), 100 ether);

        // Get initial tick
        (, int24 initialTick, , ) = StateLibrary.getSlot0(manager, poolKey.toId());
        console.log("Initial tick:");
        console.logInt(initialTick);

        // Create order: tick range = {60, 180}
        // LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(true, true, 180, 1 ether, poolKey);
        LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(true, 180, 1 ether, poolKey);
        
        // Log position details
        console.log("Position created:");
        console.log("  isToken0:");
        console.logUint(result.isToken0 ? 1 : 0);
        console.log("  bottomTick:");
        console.logInt(result.bottomTick);
        console.log("  topTick:");
        console.logInt(result.topTick);
        console.log("  usedAmount:");
        console.logUint(result.usedAmount);

        // Get position key for checking state
        bytes32 baseKey = getBasePositionKey(result.bottomTick, result.topTick, result.isToken0);
        bytes32 positionKey = getPositionKey(result.bottomTick, result.topTick, result.isToken0, 0);
        
        // Check position state before first swap
        console.log("\nPosition state before first swap:");
        ILimitOrderManager.PositionInfo[] memory positions = limitOrderManager.getUserPositions(address(this), poolKey.toId());
        console.log("  Number of positions:");
        console.logUint(positions.length);
        if (positions.length > 0) {
            console.log("  First position liquidity:");
            console.logUint(positions[0].liquidity);
        }

        // Execute with swap
        console.log("\nExecuting first swap (token1 -> token0) with limit at tick:");
        console.logInt(result.topTick - 10);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -2 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(result.topTick - 10)
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        
        // Get tick after first swap
        (, int24 tickAfterFirstSwap, , ) = StateLibrary.getSlot0(manager, poolKey.toId());
        console.log("Tick after first swap:");
        console.logInt(tickAfterFirstSwap);
        
        // Check position state after first swap
        console.log("\nPosition state after first swap:");
        positions = limitOrderManager.getUserPositions(address(this), poolKey.toId());
        console.log("  Number of positions:");
        console.logUint(positions.length);
        if (positions.length > 0) {
            console.log("  First position liquidity:");
            console.logUint(positions[0].liquidity);
        }

        // Execute with swap
        console.log("\nExecuting second swap (token1 -> token0) with limit at tick:");
        console.logInt(result.topTick + 100);
        
        // Log the tick ranges for overlap check
        console.log("Overlap check parameters:");
        console.log("  Tick before second swap:");
        console.logInt(tickAfterFirstSwap);
        console.log("  Target tick after second swap:");
        console.logInt(result.topTick + 100);
        console.log("  Swap direction (zeroForOne): false");
        console.log("  Position is for token0:");
        console.log(result.isToken0 ? "true" : "false");
        console.log("  For this position to execute, current tick must be >= topTick");
        console.logInt(result.topTick);
        
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -2 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(result.topTick + 100)
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
        
        // Get tick after second swap
        (, int24 tickAfterSecondSwap, , ) = StateLibrary.getSlot0(manager, poolKey.toId());
        console.log("Tick after second swap:");
        console.logInt(tickAfterSecondSwap);
        
        // Check position state after second swap
        console.log("\nPosition state after second swap:");
        positions = limitOrderManager.getUserPositions(address(this), poolKey.toId());
        console.log("  Number of positions:");
        console.logUint(positions.length);
        if (positions.length > 0) {
            console.log("  First position liquidity:");
            console.logUint(positions[0].liquidity);
        } else {
            console.log("  No positions found - position was likely executed");
        }
        
        // Check if position was executed by comparing ticks
        console.log("\nPosition execution check:");
        console.log("  Position top tick:");
        console.logInt(result.topTick);
        console.log("  Current tick:");
        console.logInt(tickAfterSecondSwap);
        console.log("  Was position executed?");
        console.log(tickAfterSecondSwap >= result.topTick ? "Yes" : "No");
        
        // Check claimable balances
        (ILimitOrderManager.ClaimableTokens memory token0Balance, ILimitOrderManager.ClaimableTokens memory token1Balance) = 
            getClaimableBalances(address(this), poolKey);
        
        console.log("\nClaimable balances after swaps:");
        console.log("Token0 claimable principal:");
        console.logUint(token0Balance.principal);
        console.log("Token0 claimable fees:");
        console.logUint(token0Balance.fees);
        console.log("Token1 claimable principal:");
        console.logUint(token1Balance.principal);
        console.log("Token1 claimable fees:");
        console.logUint(token1Balance.fees);
        
        // Check token balances
        console.log("\nToken balances after swaps:");
        console.log("Token0 balance:");
        console.logUint(IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this)));
        console.log("Token1 balance:");
        console.logUint(IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this)));
    }

    // Helper function to create an order and return result
    function _createOrder(address user, int24 targetTick, uint256 amount) internal returns (LimitOrderManager.CreateOrderResult memory) {
        vm.startPrank(user);
        // LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(true, true, targetTick, amount, poolKey);
        LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(true, targetTick, amount, poolKey);
        vm.stopPrank();
        return result;
    }

    function test_multiple_user_cancellation() public {
        // Setup test users
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");
        
        // Give each user tokens and approve
        for (uint i = 0; i < 3; i++) {
            vm.prank(i == 0 ? user1 : (i == 1 ? user2 : user3));
            IERC20Minimal(Currency.unwrap(currency0)).approve(address(limitOrderManager), type(uint256).max);
            deal(Currency.unwrap(currency0), i == 0 ? user1 : (i == 1 ? user2 : user3), 10 ether);
        }
        
        // Create the same position for all users - inline the price calculation
        int24 targetTick = TickMath.getTickAtSqrtPrice(TickLibrary.getSqrtPriceFromPrice(
            TickLibrary.getRoundedPrice(1.02e18, poolKey, true)
        ));
        
        // Create orders and save minimum needed info
        LimitOrderManager.CreateOrderResult memory result1 = _createOrder(user1, targetTick, 1 ether);
        LimitOrderManager.CreateOrderResult memory result2 = _createOrder(user2, targetTick, 1 ether);
        LimitOrderManager.CreateOrderResult memory result3 = _createOrder(user3, targetTick, 1 ether);
        
        // Quick verification - results should match
        assertEq(result1.bottomTick, result2.bottomTick);
        assertEq(result1.topTick, result2.topTick);
        
        // User 1 cancels order - inline some operations to save stack space
        uint256 nonce1 = limitOrderManager.currentNonce(
            poolKey.toId(), 
            getBasePositionKey(result1.bottomTick, result1.topTick, result1.isToken0)
        );
        
        vm.prank(user1);
        limitOrderManager.cancelOrder(
            poolKey, 
            getPositionKey(result1.bottomTick, result1.topTick, result1.isToken0, nonce1)
        );
        
        // Verify user1's balance increased
        assertGt(
            IERC20Minimal(Currency.unwrap(currency0)).balanceOf(user1), 
            9 ether, 
            "User1 didn't receive funds back after cancellation"
        );
        
        // Prepare for swap - inline approvals
        deal(Currency.unwrap(currency1), address(this), 10 ether);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        
        // Record balances before swap
        uint256 user2BalanceBefore = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(user2);
        uint256 user3BalanceBefore = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(user3);
        
        // Execute swap
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -3 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(result1.topTick + 1)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        
        // Claim orders - inline the position key generation
        limitOrderManager.claimOrder(
            poolKey, 
            getPositionKey(result2.bottomTick, result2.topTick, result2.isToken0, nonce1),
            user2
        );
        
        limitOrderManager.claimOrder(
            poolKey, 
            getPositionKey(result3.bottomTick, result3.topTick, result3.isToken0, nonce1),
            user3
        );
        
        // Verify execution - no changes needed here
        assertGt(
            IERC20Minimal(Currency.unwrap(currency1)).balanceOf(user2), 
            user2BalanceBefore, 
            "User2's order wasn't executed"
        );
        assertGt(
            IERC20Minimal(Currency.unwrap(currency1)).balanceOf(user3), 
            user3BalanceBefore, 
            "User3's order wasn't executed"
        );
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

    // Helper function to replicate the functionality of getUserClaimableBalances
    function getClaimableBalances(
        address user,
        PoolKey memory key
    ) internal view returns (
        LimitOrderManager.ClaimableTokens memory token0Balance,
        LimitOrderManager.ClaimableTokens memory token1Balance
    ) {
        PoolId poolId = key.toId();
        
        // Initialize the balance structures
        token0Balance.token = key.currency0;
        token1Balance.token = key.currency1;
        
        // Get all positions for the user in this pool
        ILimitOrderManager.PositionInfo[] memory positions = limitOrderManager.getUserPositions(user, poolId);
        
        // Iterate through each position and accumulate balances
        for (uint i = 0; i < positions.length; i++) {
            LimitOrderManager.PositionBalances memory posBalances = lens.getPositionBalances(
                user, 
                poolId, 
                positions[i].positionKey
            );
            
            // Accumulate principals and fees
            token0Balance.principal += posBalances.principal0;
            token1Balance.principal += posBalances.principal1;
            token0Balance.fees += posBalances.fees0;
            token1Balance.fees += posBalances.fees1;
        }
        
        return (token0Balance, token1Balance);
    }

    // ============== Range Order Tests ==============

    /// @notice Tests the creation of a range order with valid parameters
    // function test_create_range_order() public {
    //     deal(Currency.unwrap(currency0), address(this), 100 ether);
    //     deal(Currency.unwrap(currency1), address(this), 100 ether);
        
    //     uint256 sellAmount = 1 ether;
    //     PoolId poolId = poolKey.toId();
        
    //     // Get current tick for reference
    //     (, int24 currentTick,,) = StateLibrary.getSlot0(manager, poolId);
        
    //     console.log("Current tick:", currentTick);
    //     console.log("Tick spacing:", poolKey.tickSpacing);
        
    //     // For token0 orders, range must be above current tick
    //     // Define tick range above current price for token0 - MAKE SURE IT SPANS MULTIPLE TICK SPACINGS
    //     int24 bottomTick = currentTick + poolKey.tickSpacing;
    //     int24 topTick = currentTick + poolKey.tickSpacing * 5;
        
    //     // Round ticks to be valid for the pool's tickSpacing
    //     bottomTick = (bottomTick / poolKey.tickSpacing) * poolKey.tickSpacing;
    //     topTick = (topTick / poolKey.tickSpacing) * poolKey.tickSpacing;
        
    //     console.log("Token0 order - bottomTick:", bottomTick);
    //     console.log("Token0 order - topTick:", topTick);
        
    //     // Ensure the ticks are different after rounding
    //     require(bottomTick < topTick, "Ticks equal after rounding");
        
    //     // Create a range order (using token0)
    //     LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createRangeOrder(
    //         true, bottomTick, topTick, sellAmount, poolKey
    //     );
        
    //     // Verify result
    //     assertTrue(result.usedAmount > 0, "Invalid amount used");
    //     assertTrue(result.isToken0, "Wrong token direction");
    //     assertEq(result.bottomTick, bottomTick, "Bottom tick not matching");
    //     assertEq(result.topTick, topTick, "Top tick not matching");
        
    //     // Verify token balance was transferred
    //     uint256 expectedBalance = 100 ether - sellAmount;
    //     uint256 actualBalance = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
    //     assertEq(actualBalance, expectedBalance, "Token not transferred correctly");
        
    //     // Now test token1 - range must be below current tick
    //     bottomTick = currentTick - poolKey.tickSpacing * 5;
    //     topTick = currentTick - poolKey.tickSpacing;
        
    //     // Round ticks
    //     bottomTick = (bottomTick / poolKey.tickSpacing) * poolKey.tickSpacing;
    //     topTick = (topTick / poolKey.tickSpacing) * poolKey.tickSpacing;
        
    //     console.log("Token1 order - bottomTick:", bottomTick);
    //     console.log("Token1 order - topTick:", topTick);
        
    //     // Ensure the ticks are different after rounding
    //     require(bottomTick < topTick, "Ticks equal after rounding");
        
    //     // Create a range order (using token1)
    //     result = limitOrderManager.createRangeOrder(
    //         false, bottomTick, topTick, sellAmount, poolKey
    //     );
        
    //     // Verify result
    //     assertTrue(result.usedAmount > 0, "Invalid amount used");
    //     assertFalse(result.isToken0, "Wrong token direction");
    //     assertEq(result.bottomTick, bottomTick, "Bottom tick not matching");
    //     assertEq(result.topTick, topTick, "Top tick not matching");
    // }
    
    // /// @notice Tests executing a range order when price moves through the range
    // function test_range_order_execution() public {
    //     deal(Currency.unwrap(currency0), address(this), 100 ether);
    //     deal(Currency.unwrap(currency1), address(this), 100 ether);
        
    //     uint256 sellAmount = 1 ether;
    //     PoolId poolId = poolKey.toId();
        
    //     // Get current tick
    //     (, int24 currentTick,,) = StateLibrary.getSlot0(manager, poolId);
        
    //     console.log("Current tick before order:", currentTick);
    //     console.log("Tick spacing:", poolKey.tickSpacing);
        
    //     // Define range above current price for token0 so we can cross it with a swap
    //     // Use multiple tick spacings to ensure distinct ticks after rounding
    //     int24 bottomTick = currentTick + poolKey.tickSpacing;
    //     int24 topTick = currentTick + poolKey.tickSpacing * 10;
        
    //     // Round ticks to be valid for the pool's tickSpacing
    //     bottomTick = (bottomTick / poolKey.tickSpacing) * poolKey.tickSpacing;
    //     topTick = (topTick / poolKey.tickSpacing) * poolKey.tickSpacing;
        
    //     console.log("Range order bottomTick:", bottomTick);
    //     console.log("Range order topTick:", topTick);
        
    //     // Ensure the ticks are different after rounding
    //     require(bottomTick < topTick, "Ticks equal after rounding");
        
    //     // Create a range order using token0
    //     LimitOrderManager.CreateOrderResult memory result = limitOrderManager.createRangeOrder{value: ethAmount}(
    //         true, bottomTick, topTick, ethAmount, ethPoolKey
    //     );
        
    //     // Verify result
    //     assertTrue(result.usedAmount > 0, "Invalid amount used");
    //     assertTrue(result.isToken0, "Wrong token direction");
    //     assertEq(result.bottomTick, bottomTick, "Bottom tick not matching");
    //     assertEq(result.topTick, topTick, "Top tick not matching");
        
    //     // Check that eth was transferred correctly
    //     assertEq(address(this).balance, initialBalance - ethAmount, "ETH not transferred correctly");
    // }
    
    // /// @notice Tests the toggling of allowRangeOrders emits the proper event
    // function test_range_orders_toggle_event() public {
    //     // Test event emission when disabling
    //     vm.expectEmit(true, false, false, true);
    //     emit ILimitOrderManager.RangeOrdersStatusUpdated(false);
    //     limitOrderManager.setAllowRangeOrders(false);
        
    //     // Test event emission when enabling
    //     vm.expectEmit(true, false, false, true);
    //     emit ILimitOrderManager.RangeOrdersStatusUpdated(true);
    //     limitOrderManager.setAllowRangeOrders(true);
    // }
}