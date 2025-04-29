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
import {LimitOrderLens} from "src/LimitOrderLens.sol";
contract PositionManagement is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    LimitOrderHook hook;
    ILimitOrderManager limitOrderManager;
    LimitOrderLens lens;
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
    function test_minimum_amount_validation() public {
        deal(Currency.unwrap(currency0), address(this), 100 ether);
        deal(Currency.unwrap(currency1), address(this), 100 ether);

        uint256 token0Min = 0.5 ether;
        uint256 token1Min = 1 ether;

        // Set minimum amounts for both tokens
        limitOrderManager.setMinAmount(currency0, token0Min);  // 0.5 token0 minimum
        limitOrderManager.setMinAmount(currency1, token1Min);  // 1.0 token1 minimum

        (, int24 currentTick,,) = StateLibrary.getSlot0(hook.poolManager(), poolKey.toId());
        
        // Calculate a valid target tick that's far enough from current tick
        int24 validTargetTick = currentTick + 120; // Must be far enough from current tick

        // Try to create order below minimum for token0 - should revert with MinimumAmountNotMet
        uint256 lowAmount = 0.1 ether;


        bytes memory expectedError = abi.encodeWithSelector(
            ILimitOrderManager.MinimumAmountNotMet.selector,
            lowAmount,
            token0Min
        );
        vm.expectRevert(expectedError);
        limitOrderManager.createLimitOrder(true, validTargetTick, lowAmount, poolKey);

        // Create valid order for token0 with proper amount and tick spacing
        // params.amount = 1 ether;  // Above minimum
        ILimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(true, validTargetTick, 1 ether, poolKey);
        assertTrue(result.usedAmount >= token0Min, "Amount should be above minimum");

        // Try to create order below minimum for token1
        lowAmount = 0.5 ether;  // Below token1 minimum


        expectedError = abi.encodeWithSelector(
            ILimitOrderManager.MinimumAmountNotMet.selector,
            lowAmount,
            token1Min
        );
        vm.expectRevert(expectedError);
        limitOrderManager.createLimitOrder(false, currentTick - 120, lowAmount, poolKey);

        // Test that zero minimum allows any amount
        limitOrderManager.setMinAmount(currency0, 0);  // No minimum

        
        // Should not revert
        result = limitOrderManager.createLimitOrder(true, validTargetTick, 0.001 ether, poolKey);
        assertTrue(result.usedAmount > 0, "Order should be created with small amount when no minimum");
    }

    function test_multi_user_fee_distribution() public {
        // Setup users
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");
        
        uint256 initialAmount = 100 ether;
        deal(Currency.unwrap(currency0), user1, initialAmount);
        deal(Currency.unwrap(currency0), user2, initialAmount);
        deal(Currency.unwrap(currency0), user3, initialAmount);
        
        // Approve hook for all users
        vm.startPrank(user1);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(limitOrderManager), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(user2);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(limitOrderManager), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(user3);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(limitOrderManager), type(uint256).max);
        vm.stopPrank();

        // Create orders at same price point with different amounts
        (, int24 currentTick,,) = StateLibrary.getSlot0(hook.poolManager(), poolKey.toId());
        int24 targetTick = currentTick + 120;


        // User1: 1 ether
        vm.prank(user1);
        limitOrderManager.createLimitOrder(true, targetTick, 1 ether, poolKey);
        
        // User2: 2 ether (double amount)
        // params.amount = 2 ether;
        vm.prank(user2);
        limitOrderManager.createLimitOrder(true, targetTick, 2 ether, poolKey);
        
        // User3: 1 ether (same as user1)
        // params.amount = 1 ether;
        vm.prank(user3);
        limitOrderManager.createLimitOrder(true, targetTick, 1 ether, poolKey);

        // Generate fees with small swap that doesn't execute positions
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(targetTick - 10)
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );

        // Check fee distribution
        (ILimitOrderManager.ClaimableTokens memory token0Balance1,) = getClaimableBalances(user1, poolKey);
        (ILimitOrderManager.ClaimableTokens memory token0Balance2,) = getClaimableBalances(user2, poolKey);
        (ILimitOrderManager.ClaimableTokens memory token0Balance3,) = getClaimableBalances(user3, poolKey);

        // User2 should have double the fees since they provided double liquidity
        assertApproxEqRel(
            token0Balance2.fees,
            token0Balance1.fees * 2,
            1e16,
            "User2 should have double the fees"
        );

        // User1 and User3 should have equal fees since they provided equal liquidity
        assertApproxEqRel(
            token0Balance1.fees,
            token0Balance3.fees,
            1e16,
            "User1 and User3 should have equal fees"
        );
    }

    // Storage variables to fix stack too deep
    bytes32 internal testPositionKey;
    bytes32 internal testBaseKey;
    uint256 internal testNonce;

    function test_position_nonce_and_balances() public {
        address user1 = makeAddr("user1");
        uint256 initialAmount = 100 ether;
        deal(Currency.unwrap(currency0), user1, initialAmount);
        
        vm.startPrank(user1);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(limitOrderManager), type(uint256).max);
        vm.stopPrank();

        // Get current tick and set target tick higher for token0 order
        (, int24 currentTick,,) = StateLibrary.getSlot0(hook.poolManager(), poolKey.toId());
        console.log("Current tick:", currentTick);
        
        // For token0 orders:
        // 1. Current tick gets rounded to nearest tickSpacing (60)
        // 2. Then an additional tickSpacing is added
        // So we need our target tick to be more than one tickSpacing above current
        int24 targetTick = ((currentTick / 60) * 60) + 180; // At least 2 spacings higher than rounded current
        console.log("Target tick:", targetTick);


        vm.prank(user1);
        ILimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder(true, targetTick, 1 ether, poolKey);
        
        // Store initial state in storage
        testBaseKey = getBasePositionKey(result.bottomTick, result.topTick, true);
        PoolId poolId = poolKey.toId();
        testNonce = limitOrderManager.currentNonce(poolId, testBaseKey);
        testPositionKey = getPositionKey(result.bottomTick, result.topTick, true, testNonce);

        // Execute position with swap
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -2 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(targetTick + 100)
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );

        // Log new tick after swap
        (, int24 newCurrentTick,,) = StateLibrary.getSlot0(hook.poolManager(), poolKey.toId());
        console.log("Current tick after swap:", newCurrentTick);

        // Swap back down to allow new position creation
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,  // Swap in opposite direction
                amountSpecified: 2 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(currentTick)  // Back to original tick
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );

        // Create new position at same ticks
        vm.prank(user1);
        ILimitOrderManager.CreateOrderResult memory newResult = limitOrderManager.createLimitOrder(true, targetTick, 1 ether, poolKey);

        // Verify nonce increased
        uint256 newNonce = limitOrderManager.currentNonce(poolId, testBaseKey);
        assertEq(newNonce, testNonce + 1, "Nonce should have increased");

        // Check old position state
        bytes32 oldPositionKey = getPositionKey(result.bottomTick, result.topTick, true, testNonce);
        (,, bool oldIsActive,,) = limitOrderManager.positionState(poolId, oldPositionKey);
        assertFalse(oldIsActive, "Old position should be inactive");

        // Check new position state using storage for key
        testPositionKey = getPositionKey(newResult.bottomTick, newResult.topTick, true, newNonce);
        (,, bool newIsActive,,) = limitOrderManager.positionState(poolId, testPositionKey);
        assertTrue(newIsActive, "New position should be active");

        // Verify balances
        (ILimitOrderManager.ClaimableTokens memory oldBalances,) = getClaimableBalances(user1, poolKey);
        assertTrue(oldBalances.principal > 0, "Should have claimable principal from executed position");
    }

// Add these storage variables at contract level
    ILimitOrderManager.CreateOrderResult internal orderResult1;
    ILimitOrderManager.CreateOrderResult internal orderResult2;
    ILimitOrderManager.CreateOrderResult internal orderResult3;
    ILimitOrderManager.CreateOrderResult internal orderResult4;
    uint256 internal firstSwapFee1;
    uint256 internal firstSwapFee2;
    uint256 internal firstSwapFee3;
    
    function test_fee_isolation_between_positions() public {
        (address user1, address user2, address user3, address user4) = _setupUsers();
        (int24 currentTick, int24 targetTick) = _setupInitialState();
        

        _createFirstGenPositions(user1, user2, user3, true, targetTick, 1 ether);
        _verifyPositionAlignment();
        _performFirstSwap(targetTick);
        _verifyFirstSwapFees(user1, user2, user3);
        
        // Small swap back
        _performReverseSwap(currentTick);
        
        // Create User4 position and perform final swap
        _createSecondGenPosition(user4, true, targetTick, 1 ether);
        _performFinalSwap(targetTick);
        _verifyFinalFeeDistribution(user1, user2, user3, user4);
    }

    function _setupUsers() internal returns (address, address, address, address) {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");
        address user4 = makeAddr("user4");
        
        uint256 initialAmount = 100 ether;
        address[4] memory users = [user1, user2, user3, user4];
        for(uint i = 0; i < users.length; i++) {
            deal(Currency.unwrap(currency0), users[i], initialAmount);
            vm.prank(users[i]);
            IERC20Minimal(Currency.unwrap(currency0)).approve(address(limitOrderManager), type(uint256).max);
        }
        return (user1, user2, user3, user4);
    }

function test_fee_isolation_between_same_user_positions() public {
    // Setup only three users
    (address user1, address user2, address user3, ) = _setupUsers();
    (int24 currentTick, int24 targetTick) = _setupInitialState();
    
    // Create first generation positions for all three users
    _createFirstGenPositions(user1, user2, user3, true, targetTick, 1 ether);
    _verifyPositionAlignment();
    
    // Perform first swap to generate fees
    _performFirstSwap(targetTick);
    _verifyFirstSwapFees(user1, user2, user3);
    
    // Store first swap fees
    uint256 user1FirstFees = firstSwapFee1;
    
    // Small swap back to return to near original price
    _performReverseSwap(currentTick);
    
    // Have user1 create a second position at the same price point
    vm.prank(user1);
    ILimitOrderManager.CreateOrderResult memory user1SecondPosition = 
        limitOrderManager.createLimitOrder(true, targetTick, 1 ether, poolKey);
    
    // Verify position alignment
    assertEq(orderResult1.bottomTick, user1SecondPosition.bottomTick);
    assertEq(orderResult1.topTick, user1SecondPosition.topTick);
    
    // Perform final swap
    _performFinalSwap(targetTick);
    
    // Get final balances
    (ILimitOrderManager.ClaimableTokens memory user1Token0Final, 
     ILimitOrderManager.ClaimableTokens memory user1Token1Final) = 
        getClaimableBalances(user1, poolKey);
    
    (ILimitOrderManager.ClaimableTokens memory user2Token0Final, 
     ILimitOrderManager.ClaimableTokens memory user2Token1Final) = 
        getClaimableBalances(user2, poolKey);
    
    (ILimitOrderManager.ClaimableTokens memory user3Token0Final, 
     ILimitOrderManager.ClaimableTokens memory user3Token1Final) = 
        getClaimableBalances(user3, poolKey);
    
    // Log first swap and final fees using internal function
    _logFirstSwapAndFinalFees(user1FirstFees, user1Token1Final.fees, user2Token1Final.fees, user3Token1Final.fees);
    
    // User1 should have more fees than other users due to having two positions
    assertTrue(
        user1Token1Final.fees > user2Token1Final.fees,
        "User1 should have more fees than User2 due to having two positions"
    );
    
    // Calculate fee increase ratio
    uint256 user1FeeRatio = user1Token1Final.fees * 100 / user1FirstFees;
    uint256 user2FeeRatio = user2Token1Final.fees * 100 / firstSwapFee2;
    
    console.log("\nFee increase ratios (percentage of initial fees):");
    console.log("User1:", user1FeeRatio, "%");
    console.log("User2:", user2FeeRatio, "%");
    
    assertTrue(
        user1FeeRatio > user2FeeRatio,
        "User1's fee growth ratio should be larger due to second position"
    );
    
    // Track balances for claiming
    _trackAndExecuteClaims(user1);
    _trackAndExecuteClaims(user2);
    _trackAndExecuteClaims(user3);
    
    // Log claimed amounts using internal function
    _logClaimedAmounts3Users(user1, user2, user3);
    
    // User1 should receive significantly more tokens due to having two positions
    // uint256 user1ClaimedAmount = userBalanceDeltas[user1].token1After - userBalanceDeltas[user1].token1Before;
    // uint256 user2ClaimedAmount = userBalanceDeltas[user2].token1After - userBalanceDeltas[user2].token1Before;
    
    // assertTrue(
    //     user1ClaimedAmount > user2ClaimedAmount * 15 / 10,
    //     "User1 should receive at least 50% more token1 than User2 after claiming"
    // );
}

// Internal function for logging initial fees and final balances
function _logFirstSwapAndFinalFees(
    uint256 user1FirstFees,
    uint256 user1FinalFees,
    uint256 user2FinalFees,
    uint256 user3FinalFees
) internal {
    console.log("First swap fees (token1):");
    console.log("User1 first fees:", user1FirstFees);
    console.log("User2 first fees:", firstSwapFee2);
    console.log("User3 first fees:", firstSwapFee3);
    
    console.log("\nFinal balances (token1):");
    console.log("User1 final fees:", user1FinalFees);
    console.log("User2 final fees:", user2FinalFees);
    console.log("User3 final fees:", user3FinalFees);
}

// Internal function for logging claimed amounts for three users
function _logClaimedAmounts3Users(
    address user1,
    address user2,
    address user3
) internal view {
    console.log("\nActual claimed amounts (token1):");
    console.log("User1 claimed:", userBalanceDeltas[user1].token1After - userBalanceDeltas[user1].token1Before);
    console.log("User2 claimed:", userBalanceDeltas[user2].token1After - userBalanceDeltas[user2].token1Before);
    console.log("User3 claimed:", userBalanceDeltas[user3].token1After - userBalanceDeltas[user3].token1Before);
}

    function _setupInitialState() internal view returns (int24, int24) {
        (, int24 currentTick,,) = StateLibrary.getSlot0(hook.poolManager(), poolKey.toId());
        int24 targetTick = currentTick + 300;
        return (currentTick, targetTick);
    }

    function _createFirstGenPositions(
        address user1,
        address user2,
        address user3,
        bool isToken0,
        int24 targetTick,
        uint256 amount
    ) internal {
        vm.prank(user1);
        orderResult1 = limitOrderManager.createLimitOrder(isToken0,targetTick, amount, poolKey);
        
        vm.prank(user2);
        orderResult2 = limitOrderManager.createLimitOrder(isToken0, targetTick, amount, poolKey);
        
        vm.prank(user3);
        orderResult3 = limitOrderManager.createLimitOrder(isToken0, targetTick, amount, poolKey);
    }

    function _verifyPositionAlignment() internal view {
        assertEq(orderResult1.bottomTick, orderResult2.bottomTick, "User1 and User2 bottom ticks differ");
        assertEq(orderResult2.bottomTick, orderResult3.bottomTick, "User2 and User3 bottom ticks differ");
        assertEq(orderResult1.topTick, orderResult2.topTick, "User1 and User2 top ticks differ");
        assertEq(orderResult2.topTick, orderResult3.topTick, "User2 and User3 top ticks differ");
    }

    function _performFirstSwap(int24 targetTick) internal {
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -2.5 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(targetTick - 10)
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
    }

    function _verifyFirstSwapFees(address user1, address user2, address user3) internal {
        (ILimitOrderManager.ClaimableTokens memory balance1token0, ILimitOrderManager.ClaimableTokens memory balance1token1) = 
            getClaimableBalances(user1, poolKey);
        (ILimitOrderManager.ClaimableTokens memory balance2token0, ILimitOrderManager.ClaimableTokens memory balance2token1) = 
            getClaimableBalances(user2, poolKey);
        (ILimitOrderManager.ClaimableTokens memory balance3token0, ILimitOrderManager.ClaimableTokens memory balance3token1) = 
            getClaimableBalances(user3, poolKey);

        // Store both token fees for each user
        firstSwapFee1 = balance1token1.fees;  // Changed from token0 to token1
        firstSwapFee2 = balance2token1.fees;  // Changed from token0 to token1
        firstSwapFee3 = balance3token1.fees;  // Changed from token0 to token1

        console.log("First swap token1 fees:");
        console.log("User1:", balance1token1.fees);
        console.log("User2:", balance2token1.fees);
        console.log("User3:", balance3token1.fees);

        assertApproxEqRel(balance1token1.fees, balance2token1.fees, 1e16, "First swap: User1 and User2 should have equal fees");
        assertApproxEqRel(balance2token1.fees, balance3token1.fees, 1e16, "First swap: User2 and User3 should have equal fees");
    }

    function _performReverseSwap(int24 currentTick) internal {
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 2.4 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(currentTick)
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
    }

    function _createSecondGenPosition(address user4, bool isToken0, int24 targetTick, uint256 amount) internal {
        vm.prank(user4);
        orderResult4 = limitOrderManager.createLimitOrder(isToken0, targetTick, amount, poolKey);
        assertEq(orderResult1.bottomTick, orderResult4.bottomTick, "User4 bottom tick differs");
        assertEq(orderResult1.topTick, orderResult4.topTick, "User4 top tick differs");
        (ILimitOrderManager.ClaimableTokens memory balance1token0, ILimitOrderManager.ClaimableTokens memory balance1token1) = 
        getClaimableBalances(user4, poolKey);
        console.log("User4:", balance1token1.fees);
    }

    function _performFinalSwap(int24 targetTick) internal {
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -2.5 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(targetTick - 10)
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );
    }

// Add these as contract storage variables
struct UserBalances {
    uint256 token0Before;
    uint256 token1Before;
    uint256 token0After;
    uint256 token1After;
}

mapping(address => UserBalances) internal userBalanceDeltas;

function _verifyFinalFeeDistribution(address user1, address user2, address user3, address user4) internal {
    // First log the fees as before
    _logFinalFees(user1, user2, user3, user4);
    
    // Track and execute claims
    _trackAndExecuteClaims(user1);
    _trackAndExecuteClaims(user2);
    _trackAndExecuteClaims(user3);
    _trackAndExecuteClaims(user4);

    // Log the final claimed amounts
    _logClaimedAmounts(user1, user2, user3, user4);
}

function _logFinalFees(address user1, address user2, address user3, address user4) internal view {
    (ILimitOrderManager.ClaimableTokens memory finalBalance1Token0, ILimitOrderManager.ClaimableTokens memory finalBalance1Token1) = getClaimableBalances(user1, poolKey);
    (ILimitOrderManager.ClaimableTokens memory finalBalance2Token0, ILimitOrderManager.ClaimableTokens memory finalBalance2Token1) = getClaimableBalances(user2, poolKey);
    (ILimitOrderManager.ClaimableTokens memory finalBalance3Token0, ILimitOrderManager.ClaimableTokens memory finalBalance3Token1) = getClaimableBalances(user3, poolKey);
    (ILimitOrderManager.ClaimableTokens memory finalBalance4Token0, ILimitOrderManager.ClaimableTokens memory finalBalance4Token1) = getClaimableBalances(user4, poolKey);

    console.log("First swap fees (token1):");
    console.log("User1 first fees:", firstSwapFee1);
    console.log("User2 first fees:", firstSwapFee2);
    console.log("User3 first fees:", firstSwapFee3);

    console.log("\nFinal balances (token0):");
    console.log("User1 final fees:", finalBalance1Token0.fees);
    console.log("User2 final fees:", finalBalance2Token0.fees);
    console.log("User3 final fees:", finalBalance3Token0.fees);
    console.log("User4 final fees:", finalBalance4Token0.fees);

    console.log("\nFinal balances (token1):");
    console.log("User1 final fees:", finalBalance1Token1.fees);
    console.log("User2 final fees:", finalBalance2Token1.fees);
    console.log("User3 final fees:", finalBalance3Token1.fees);
    console.log("User4 final fees:", finalBalance4Token1.fees);
}

function _trackAndExecuteClaims(address user) internal {
    // Store initial balances
    UserBalances storage balances = userBalanceDeltas[user];
    balances.token0Before = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(user);
    balances.token1Before = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(user);

    // Get and cancel all positions
    ILimitOrderManager.PositionInfo[] memory positions = limitOrderManager.getUserPositions(user, poolKey.toId());
    uint256 posLength = positions.length > 100 ? 100 : positions.length;
    vm.startPrank(user);
    for (uint256 i = 0; i < posLength; i++) {
        limitOrderManager.cancelOrder(poolKey, positions[i].positionKey);
    }
    vm.stopPrank();

    // Store final balances
    balances.token0After = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(user);
    balances.token1After = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(user);
}

function _logClaimedAmounts(address user1, address user2, address user3, address user4) internal view {
    console.log("\nActual claimed amounts (token0):");
    console.log("User1 claimed:", userBalanceDeltas[user1].token0After - userBalanceDeltas[user1].token0Before);
    console.log("User2 claimed:", userBalanceDeltas[user2].token0After - userBalanceDeltas[user2].token0Before);
    console.log("User3 claimed:", userBalanceDeltas[user3].token0After - userBalanceDeltas[user3].token0Before);
    console.log("User4 claimed:", userBalanceDeltas[user4].token0After - userBalanceDeltas[user4].token0Before);

    console.log("\nActual claimed amounts (token1):");
    console.log("User1 claimed:", userBalanceDeltas[user1].token1After - userBalanceDeltas[user1].token1Before);
    console.log("User2 claimed:", userBalanceDeltas[user2].token1After - userBalanceDeltas[user2].token1Before);
    console.log("User3 claimed:", userBalanceDeltas[user3].token1After - userBalanceDeltas[user3].token1Before);
    console.log("User4 claimed:", userBalanceDeltas[user4].token1After - userBalanceDeltas[user4].token1Before);
}

    // Helper function to get leftover positions
    function getLeftoverPositions(PoolId poolId) internal view returns (ILimitOrderManager.PositionTickRange[] memory) {
        // Get user position keys
        ILimitOrderManager.PositionInfo[] memory positions = limitOrderManager.getUserPositions(address(this), poolId);
        uint256 posLength = positions.length > 100 ? 100 : positions.length;
        ILimitOrderManager.PositionTickRange[] memory leftoverPositions = new ILimitOrderManager.PositionTickRange[](posLength);
        
        uint256 count = 0;
        for(uint i = 0; i < posLength; i++) {
            // Decode position key
            (int24 bottomTick, int24 topTick, bool isToken0,) = _decodePositionKey(positions[i].positionKey);
            leftoverPositions[count] = ILimitOrderManager.PositionTickRange({
                bottomTick: bottomTick,
                topTick: topTick,
                isToken0: isToken0
            });
            count++;
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

    // Decode position key to get all components including nonce
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
    
    // Helper function to replicate the functionality of getUserClaimableBalances
    function getClaimableBalances(
        address user,
        PoolKey memory key
    ) internal view returns (
        ILimitOrderManager.ClaimableTokens memory token0Balance,
        ILimitOrderManager.ClaimableTokens memory token1Balance
    ) {
        PoolId poolId = key.toId();
        
        // Initialize the balance structures
        token0Balance.token = key.currency0;
        token1Balance.token = key.currency1;
        
        // Get all positions for the user in this pool
        ILimitOrderManager.PositionInfo[] memory positions = limitOrderManager.getUserPositions(user, poolId);
        
        // Iterate through each position and accumulate balances
        for (uint i = 0; i < positions.length; i++) {
            ILimitOrderManager.PositionBalances memory posBalances = lens.getPositionBalances(
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
}