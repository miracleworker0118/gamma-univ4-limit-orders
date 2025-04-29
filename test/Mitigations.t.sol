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
import {StateView} from "v4-periphery/src/lens/StateView.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LimitOrderHook} from "src/LimitOrderHook.sol";
import {LimitOrderManager} from "src/LimitOrderManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ILimitOrderManager} from "src/ILimitOrderManager.sol";
import {MockHooks} from "v4-core/test/MockHooks.sol";
import "../src/TickLibrary.sol";
import {LimitOrderLens} from "src/LimitOrderLens.sol";

contract Mitigations is Test, Deployers {
    error NotPoolManager();

    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    uint256 public HOOK_FEE_PERCENTAGE = 50000;
    uint256 public constant FEE_DENOMINATOR = 100000;
    uint256 internal constant Q128 = 1 << 128;
    LimitOrderHook hook;
    LimitOrderManager orderManager;
    LimitOrderLens lens;
    address orderManagerAddr;
    address public treasury;
    PoolKey poolKey;
    PoolId poolId;
    address public creator1 = vm.addr(1);
    address public creator2 = vm.addr(2);
    address public creator3 = vm.addr(3);
    StateView public state;

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

        orderManagerAddr = address(orderManager);
        
        // Deploy LimitOrderLens for querying position data
        lens = new LimitOrderLens(
            orderManagerAddr,
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
        orderManager.setExecutablePositionsLimit(5);
        orderManager.setHook(address(hook));
        // Initialize pool with 1:1 price
        (poolKey,) = initPool(currency0, currency1, hook, 3000, TickMath.getSqrtPriceAtTick(-1));
        poolId = poolKey.toId();

        orderManager.setWhitelistedPool(poolKey.toId(), true);

        // assigne pool manager to state view
        state = new StateView(manager);
        
        // Approve tokens to manager
        IERC20Minimal(Currency.unwrap(currency0)).approve(orderManagerAddr, type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(orderManagerAddr, type(uint256).max);
    }

    // gammauniv4limitorder Merged Findings Table: C-01
    function test_anyone_can_trigger_orders() public {
        // create orders
        _createScaleOrder(creator1, true, 100, 300, 3 ether, 3, 1e18);
        vm.expectRevert();
        orderManager.executeOrder(poolKey, 0, 330, false);
    }

    // gammauniv4limitorder Merged Findings Table: C-02
    function test_position_liquidity_unalter_by_cancel() public {
        // create limit order
        ILimitOrderManager.CreateOrderResult memory result = _createLimitOrder(creator1, true, 300, 1 ether);
        bytes32 positionKey = _getPositionKey(result.bottomTick, result.topTick, result.isToken0);
        
        // Get liquidity for this position
        (uint128 realLiq, , ) = StateLibrary.getPositionInfo(
            manager,
            poolId,
            orderManagerAddr,
            result.bottomTick,
            result.topTick,
            bytes32(0)
        );
        (, uint128 positionStateLiq, , , ) = orderManager.positionState( poolId, positionKey);
        assertEq(positionStateLiq, realLiq);
        // swap 
        _swap(200, false, 1 ether);
        // cancel order
        vm.prank(creator1);
        orderManager.cancelOrder(poolKey, positionKey);
        (realLiq, , ) = StateLibrary.getPositionInfo(
            manager,
            poolId,
            orderManagerAddr,
            result.bottomTick,
            result.topTick,
            bytes32(0)
        );
        (, positionStateLiq, , , ) = orderManager.positionState( poolId, positionKey);
        assertEq(positionStateLiq, realLiq);
    }

    // // gammauniv4limitorder Merged Findings Table: C-03
    // function test_range_and_scaleOrders_arbitraged() public {
    //     address creator = creator1;
    //     address attacker = creator2;
    //     deal(Currency.unwrap(currency0), address(creator), 1000 ether);
    //     deal(Currency.unwrap(currency1), address(creator), 1000 ether);
    //     deal(Currency.unwrap(currency0), address(attacker), 1000 ether);
    //     deal(Currency.unwrap(currency0), address(attacker), 1000 ether);

    //     console.log("\n <<<<< create range order without manipulating >>>>>");
    //     console.log("--- Create a range order ---");
    //     uint256 balanceBeforeCreateOrder_0 = currency0.balanceOf(creator);
    //     uint256 balanceBeforeCreateOrder_1 = currency1.balanceOf(creator);
    //     vm.startPrank(creator);
    //     IERC20Minimal(Currency.unwrap(currency0)).approve(orderManagerAddr, 1 ether);
    //     ILimitOrderManager.CreateOrderResult memory result = orderManager.createLimitOrder(true, true, 2000, 1 ether, poolKey);
    //     bytes32 positionKey = _getPositionKey(result.bottomTick, result.topTick, result.isToken0);
    //     vm.stopPrank();
    //     uint256 balanceAfterCreateOrder_0 = currency0.balanceOf(creator);
    //     uint256 balanceAfterCreateOrder_1 = currency1.balanceOf(creator);
    //     console.log("Amount spent to create order in token zero: ", balanceBeforeCreateOrder_0 - balanceAfterCreateOrder_0);
    //     console.log("Amount spent to create order in token one: ", balanceBeforeCreateOrder_1 - balanceAfterCreateOrder_1);
    //     console.log("Order bottom tick: ", result.bottomTick);
    //     console.log("Order top tick: ", result.topTick);
    //     (uint128 posLiq, , ) = StateLibrary.getPositionInfo(
    //         manager,
    //         poolId,
    //         orderManagerAddr,
    //         result.bottomTick,
    //         result.topTick,
    //         bytes32(0)
    //     );
    //     console.log("Position's liquidity: ", posLiq);

    //     console.log("\n--- Swap so order is executed ---");
    //     uint256 balanceBeforeSwap_0 = currency0.balanceOf(attacker);
    //     uint256 balanceBeforeSwap_1 = currency1.balanceOf(attacker);
    //     BalanceDelta attackerDelta = _swap(2100, false, 2 ether);
    //     console.log("Attacker gained amount in token zero: ", attackerDelta.amount0());
    //     console.log("Attacker gained amount in token one: ", attackerDelta.amount1());

    //     uint256 balanceAfterExecuteOrder_0 = currency0.balanceOf(creator);
    //     uint256 balanceAfterExecuteOrder_1 = currency1.balanceOf(creator);
    //     console.log("Amount received after order execution in token zero: ", balanceAfterExecuteOrder_0 - balanceAfterCreateOrder_0);
    //     console.log("Amount received after order execution in token one: ", balanceAfterExecuteOrder_1 - balanceAfterCreateOrder_1);

    //     console.log("\n--- Claim order ---");
    //     vm.prank(creator);
    //     orderManager.claimOrder(poolKey, positionKey, creator);
    //     uint256 balanceAfterClaimOrder_0 = currency0.balanceOf(creator);
    //     uint256 balanceAfterClaimOrder_1 = currency1.balanceOf(creator);
    //     console.log("Amount received after order claim in token zero: ", balanceAfterClaimOrder_0 - balanceAfterExecuteOrder_0);
    //     console.log("Amount received after order claim in token one: ", balanceAfterClaimOrder_1 - balanceAfterExecuteOrder_1);

    //     console.log("\n<<<<< create range order under manipulating >>>>>");
    //     console.log("--- attacker moves tick to -10000 to get benefit from range orders ---");
    //     attackerDelta = _swap(-10000, true, 2 ether);
    //     console.log("Attacked used in token zero: ", attackerDelta.amount0());
    //     console.log("Attacked used in token one: ", attackerDelta.amount1());
    //     console.log("--- Create a range order ---");
    //     balanceBeforeCreateOrder_0 = currency0.balanceOf(creator);
    //     balanceBeforeCreateOrder_1 = currency1.balanceOf(creator);
    //     vm.startPrank(creator);
    //     IERC20Minimal(Currency.unwrap(currency0)).approve(orderManagerAddr, 1 ether);
    //     result = orderManager.createLimitOrder(true, true, 2000, 1 ether, poolKey);
    //     positionKey = _getPositionKey(result.bottomTick, result.topTick, result.isToken0);
    //     vm.stopPrank();
    //     balanceAfterCreateOrder_0 = currency0.balanceOf(creator);
    //     balanceAfterCreateOrder_1 = currency1.balanceOf(creator);
    //     console.log("Amount spent to create order in token zero: ", balanceBeforeCreateOrder_0 - balanceAfterCreateOrder_0);
    //     console.log("Amount spent to create order in token one: ", balanceBeforeCreateOrder_1 - balanceAfterCreateOrder_1);
    //     console.log("Order bottom tick: ", result.bottomTick);
    //     console.log("Order top tick: ", result.topTick);
    //     (posLiq, , ) = StateLibrary.getPositionInfo(
    //         manager,
    //         poolId,
    //         orderManagerAddr,
    //         result.bottomTick,
    //         result.topTick,
    //         bytes32(0)
    //     );
    //     console.log("Position's liquidity: ", posLiq);

    //     console.log("\n--- Swap so order is executed ---");
    //     attackerDelta = _swap(2100, false, 2 ether);
    //     console.log("Attacker gained amount in token zero: ", attackerDelta.amount0());
    //     console.log("Attacker gained amount in token one: ", attackerDelta.amount1());

    //     balanceAfterExecuteOrder_0 = currency0.balanceOf(creator);
    //     balanceAfterExecuteOrder_1 = currency1.balanceOf(creator);
    //     console.log("Amount received after order execution in token zero: ", balanceAfterExecuteOrder_0 - balanceAfterCreateOrder_0);
    //     console.log("Amount received after order execution in token one: ", balanceAfterExecuteOrder_1 - balanceAfterCreateOrder_1);

    //     console.log("\n --- Claim order ---");
    //     vm.prank(creator);
    //     orderManager.claimOrder(poolKey, positionKey, creator);
    //     balanceAfterClaimOrder_0 = currency0.balanceOf(creator);
    //     balanceAfterClaimOrder_1 = currency1.balanceOf(creator);
    //     console.log("Amount received after order claim in token zero: ", balanceAfterClaimOrder_0 - balanceAfterExecuteOrder_0);
    //     console.log("Amount received after order claim in token one: ", balanceAfterClaimOrder_1 - balanceAfterExecuteOrder_1);
    // }

    // C-05 Wrongful liquidity burn can cause loss of funds
    function test_wrongful_liquidity_burn() public {
        // console.log("\n <<< Create 1st order >>>");
        // ILimitOrderManager.CreateOrderResult memory result = _createLimitOrder(creator1, true, true, 300, 1 ether);
        // bytes32 baseKey = _getBaseKey(result.bottomTick, result.topTick, result.isToken0);
        // console.log("Bottom Tick: ", result.bottomTick);
        // console.log("Top Tick: ", result.topTick);
        // // console.log("Base key: ", baseKey);
        // uint256 currentNonce = orderManager.currentNonce(poolId, baseKey);
        // console.log("Current Nonce: ", currentNonce);
        // console.log("--- Swap so order is executed. ---");
        // _swap(310, false, 1 ether);
        // _swap(-1, true, 1 ether);

        // console.log("\n <<< Create 2nd order >>>");
        // result = _createLimitOrder(creator1, true, true, 300, 1 ether);
        // baseKey = _getBaseKey(result.bottomTick, result.topTick, result.isToken0);
        // console.log("Bottom Tick: ", result.bottomTick);
        // console.log("Top Tick: ", result.topTick);
        // // console.log("Base key: ", baseKey);
        // currentNonce = orderManager.currentNonce(poolId, baseKey);
        // console.log("Current Nonce: ", currentNonce);
        // console.log("--- Swap so order is executed. ---");
        // _swap(310, false, 1 ether);
        // _swap(-1, true, 1 ether);

        deal(Currency.unwrap(currency0), address(creator1), 1000 ether);
        deal(Currency.unwrap(currency1), address(creator1), 1000 ether);
        deal(Currency.unwrap(currency0), address(creator2), 1000 ether);
        deal(Currency.unwrap(currency0), address(creator2), 1000 ether);

        console.log("\n--- User1 create limit order ---");
        uint256 creator1BalanceBefore0 = currency0.balanceOf(creator1);
        uint256 creator1BalanceBefore1 = currency1.balanceOf(creator1);
        vm.startPrank(creator1);
        IERC20Minimal(Currency.unwrap(currency0)).approve(orderManagerAddr, 1 ether);
        ILimitOrderManager.CreateOrderResult memory result = orderManager.createLimitOrder(true,  120, 1 ether, poolKey);
        vm.stopPrank();
        bytes32 positionKey1 = _getPositionKey(result.bottomTick, result.topTick, result.isToken0);
        uint256 creator1BalanceAfter0 = currency0.balanceOf(creator1);
        uint256 creator1BalanceAfter1 = currency1.balanceOf(creator1);
        console.log("Token Zero amount used in order creating: ", creator1BalanceBefore0 - creator1BalanceAfter0);
        console.log("Token One amount used in order creating: ", creator1BalanceBefore1 - creator1BalanceAfter1);
        console.log("\n--- Swap so order is executed ---");
        _swap(180, false, 1 ether);
        _swap(-1, true, 1 ether);
        console.log("\n--- User2 create limit order ---");
        vm.startPrank(creator2);
        IERC20Minimal(Currency.unwrap(currency0)).approve(orderManagerAddr, 2 ether);
        result = orderManager.createLimitOrder(true,  120, 2 ether, poolKey);
        vm.stopPrank();
        bytes32 positionKey2 = _getPositionKey(result.bottomTick, result.topTick, result.isToken0);
        uint256 creator2BalanceAfter0 = currency0.balanceOf(creator2);
        uint256 creator2BalanceAfter1 = currency1.balanceOf(creator2);
        console.log("\n--- User 1 cancel his order ---");
        vm.prank(creator1);
        orderManager.cancelOrder(poolKey, positionKey1);
        uint256 creator1BalanceAfterCancel0 = currency0.balanceOf(creator1);
        uint256 creator1BalanceAfterCancel1 = currency1.balanceOf(creator1);
        console.log("Token Zero amount received from order canceling: ", creator1BalanceAfterCancel0 - creator1BalanceAfter0);
        console.log("Token One amount received from order canceling: ", creator1BalanceAfterCancel1 - creator1BalanceAfter1);

        console.log("\n--- Swap so order is executed ---");
        _swap(180, false, 1 ether);
        console.log("\n--- User 2 cancel his order ---");
        ( uint128 creator2Liq, , BalanceDelta claimablePrincipal, ) = orderManager.userPositions(poolId, positionKey2, creator2);
        console.log("User2 Liquidity: ", creator2Liq);
        console.log("User2 claimablePrincipal in token zero: ", claimablePrincipal.amount0());
        console.log("User2 claimablePrincipal in token one: ", claimablePrincipal.amount1());

        vm.prank(creator2);
        orderManager.cancelOrder(poolKey, positionKey2);
        uint256 creator2BalanceAfterCancel0 = currency0.balanceOf(creator2);
        uint256 creator2BalanceAfterCancel1 = currency1.balanceOf(creator2);
        console.log("Token Zero amount received from order canceling: ", creator2BalanceAfterCancel0 - creator2BalanceAfter0);
        console.log("Token One amount received from order canceling: ", creator2BalanceAfterCancel1 - creator2BalanceAfter1);
    }
    
    // C-06 No access control in hook callback functions
    function test_invalid_call_hook() public {
        console.log("\n<<< Create order >>>");
        _createLimitOrder(creator1, true, 200, 3 ether);
        _createLimitOrder(creator2, false, -200, 3 ether);

        BalanceDelta balanceDelta = toBalanceDelta(1e18, 1e18);
        
        // Test beforeSwap with invalid caller
        vm.expectRevert(NotPoolManager.selector);
        hook.beforeSwap(
            address(this),
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(300)
            }),
            ""
        );
        
        vm.expectRevert(NotPoolManager.selector);
        hook.beforeSwap(
            address(this),
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(300)
            }),
            ""
        );

        // Test afterSwap with invalid caller
        vm.expectRevert(NotPoolManager.selector);
        hook.afterSwap(
            address(this), 
            poolKey, 
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(300)
            }),
            balanceDelta,
            ""
        );

        vm.expectRevert(NotPoolManager.selector);
        hook.afterSwap(
            address(this), 
            poolKey, 
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(300)
            }),
            balanceDelta,
            ""
        );
    }

    // // C-07 User Remains Position Contributor
    // function test_userRemainsAsContributor_afterCancelOrder() public {
    //     bytes32 posKey = _getPositionKey(60, 120, true);
    //     uint256 contributorsAmount = orderManager.getPositionContributorsLength(poolId, posKey);
    //     console.log("Amount of contributors before create order: ", contributorsAmount);
    //     assertEq(contributorsAmount, 0);

    //     ILimitOrderManager.CreateOrderResult memory result = _createRangeOrder(creator1, true, 60, 120, 1 ether);
    //     assertEq(result.bottomTick, 60);
    //     assertEq(result.topTick, 120);
    //     assertEq(result.isToken0, true);

    //     contributorsAmount = orderManager.getPositionContributorsLength(poolId, posKey);
    //     console.log("Amount of contributors after create order: ", contributorsAmount);
    //     assertEq(contributorsAmount, 1);

    //     vm.prank(creator1);
    //     orderManager.cancelOrder(poolKey, posKey);

    //     contributorsAmount = orderManager.getPositionContributorsLength(poolId, posKey);
    //     console.log("Amount of contributors after cancel order: ", contributorsAmount);
    //     ( , , bool isActive, , ) = orderManager.positionState(poolId, posKey);
    //     console.log("After canceling, position's isActive state: ", isActive);
    //     // assertEq(contributorsAmount, 1);

    //     console.log("After canceling order, user creates order on the same position again.");
    //     result = _createRangeOrder(creator1, true, 60, 120, 3 ether);
    //     contributorsAmount = orderManager.getPositionContributorsLength(poolId, posKey);
    //     console.log("Amount of contributors after create order again: ", contributorsAmount);
    //     console.log("User try to cancel his order again");
    //     vm.prank(creator1);
    //     orderManager.cancelOrder(poolKey, posKey);
    // }

    // H-01 Pools With Low SqrtPrices Are Unusable
    // function test_settleDust() public {
        
    // }

    // H-02 Incorrect Positions Removed In executeOrderByKeeper
    // function test_incorrectPositionRemove_inExecuteOrderByKeeper() public {
    //     uint256 executablePositionsLimit = 2;
    //     orderManager.setExecutablePositionsLimit(executablePositionsLimit);
        
    //     address[] memory keepers = new address[](1);
    //     keepers[0] = vm.addr(10);
    //     orderManager.flipKeepers(keepers);
    //     console.log("Keepers are set: ", orderManager.isKeeper(keepers[0]));

    //     ILimitOrderManager.CreateOrderResult[] memory orders = _createScaleOrder(creator1, true, 60, 600, 9 ether, 9, 1e18);
    //     console.log("Amount of created orders: ", orders.length);

    //     ILimitOrderManager.PositionTickRange[] memory positionList = orderManager.getPositionList(poolId, true);
    //     assertEq(positionList.length, orders.length);
        
    //     _swap(610, false, 10 ether);

    //     positionList = orderManager.getPositionList(poolId, true);
    //     assertEq(positionList.length, orders.length - executablePositionsLimit);

    //     ILimitOrderManager.PositionTickRange[] memory waitingPositions = new ILimitOrderManager.PositionTickRange[](3);
    //     waitingPositions[0] = ILimitOrderManager.PositionTickRange({bottomTick: 180, topTick: 240, isToken0: true});
    //     waitingPositions[1] = ILimitOrderManager.PositionTickRange({bottomTick: 360, topTick: 420, isToken0: true});
    //     waitingPositions[2] = ILimitOrderManager.PositionTickRange({bottomTick: 540, topTick: 600, isToken0: true});

    //     vm.prank(keepers[0]);
    //     orderManager.executeOrderByKeeper(poolKey, waitingPositions);

    //     positionList = orderManager.getPositionList(poolId, true);
    //     assertEq(positionList.length, orders.length - executablePositionsLimit - waitingPositions.length);

    //     assertEq(positionList[0].bottomTick, 240);
    //     assertEq(positionList[0].topTick, 300);
    //     assertEq(positionList[1].bottomTick, 300);
    //     assertEq(positionList[1].topTick, 360);
    //     assertEq(positionList[2].bottomTick, 420);
    //     assertEq(positionList[2].topTick, 480);
    //     assertEq(positionList[3].bottomTick, 480);
    //     assertEq(positionList[3].topTick, 540);
    // }

    // H-03 Execution of orders can be skipped
    // function test_executionOfOrders_skipped() public {
    //     ILimitOrderManager.CreateOrderResult memory result = _createRangeOrder(creator1, true, 60, 300, 2 ether);
    //     bytes32 posKey = _getPositionKey(result.bottomTick, result.topTick, result.isToken0);
    //     (, , bool isActive, , ) = orderManager.positionState(poolId, posKey);
    //     assertEq(isActive, true);
    //     ILimitOrderManager.PositionTickRange[] memory positionList = orderManager.getPositionList(poolId, true);
    //     assertEq(positionList.length, 1);

    //     _swap(100, false, 3 ether);

    //     (, , isActive, , ) = orderManager.positionState(poolId, posKey);
    //     assertEq(isActive, true);
    //     positionList = orderManager.getPositionList(poolId, true);
    //     assertEq(positionList.length, 1);

    //     _swap(400, false, 3 ether);

    //     (, , isActive, , ) = orderManager.positionState(poolId, posKey);
    //     assertEq(isActive, false);
    //     positionList = orderManager.getPositionList(poolId, true);
    //     assertEq(positionList.length, 0);
    // }

    // H-05 Batch Cancels Cause Users To Cancel Incorrectly
    // function test_cancelBatchOrders_cancelIncorrectly() public {
    //     uint256 offset = 0;
    //     uint256 limit = 3;
    //     ILimitOrderManager.CreateOrderResult[] memory results = _createScaleOrder(creator1, true, 60, 660, 10 ether, 10, 1e18);
    //     ILimitOrderManager.PositionTickRange[] memory listBeforeCancel = orderManager.getPositionList(poolId, true);

    //     vm.prank(creator1);
    //     orderManager.cancelBatchOrders(poolKey, offset, limit);

    //     ILimitOrderManager.PositionTickRange[] memory listAfterCancel = orderManager.getPositionList(poolId, true);
    //     for(uint256 i = 0; i < listAfterCancel.length; i++) {
    //         assertEq(listAfterCancel[i].bottomTick, listBeforeCancel[i + limit].bottomTick);
    //         assertEq(listAfterCancel[i].topTick, listBeforeCancel[i + limit].topTick);
    //     }
    // }

    // function test_cancelBatchOrders_withNonZeroOffset() public {
    //     // Create 10 scale orders for testing
    //     ILimitOrderManager.CreateOrderResult[] memory results = _createScaleOrder(creator1, true, 60, 660, 10 ether, 10, 1e18);
        
    //     // Get the original list of positions
    //     ILimitOrderManager.PositionTickRange[] memory originalList = orderManager.getPositionList(poolId, true);
        
    //     // Set a non-zero offset and limit
    //     uint256 offset = 5;
    //     uint256 limit = 3;
        
    //     // Cancel positions with the non-zero offset
    //     vm.prank(creator1);
    //     uint256 canceledCount = orderManager.cancelBatchOrders(poolKey, offset, limit);
        
    //     // Verify correct number of positions were canceled
    //     assertEq(canceledCount, limit);
        
    //     // Get the updated position list after cancellation
    //     ILimitOrderManager.PositionTickRange[] memory updatedList = orderManager.getPositionList(poolId, true);
        
    //     // Should have 7 positions left (original 10 minus 3 canceled)
    //     assertEq(updatedList.length, originalList.length - limit);
        
    //     // Check positions 0-4 remain unchanged
    //     for (uint256 i = 0; i < offset; i++) {
    //         assertEq(updatedList[i].bottomTick, originalList[i].bottomTick);
    //         assertEq(updatedList[i].topTick, originalList[i].topTick);
    //     }
        
    //     // Check positions 8-9 are now at positions 5-6
    //     for (uint256 i = offset; i < updatedList.length; i++) {
    //         assertEq(updatedList[i].bottomTick, originalList[i + limit].bottomTick);
    //         assertEq(updatedList[i].topTick, originalList[i + limit].topTick);
    //     }
    // }
    
    // L-01 Insufficient Event Data
    function test_update_event_LimitOrderClaimed() public {
        ILimitOrderManager.CreateOrderResult memory result = _createLimitOrder(creator1, true, 120, 10 ether);
        bytes32 posKey = _getPositionKey(result.bottomTick, result.topTick, result.isToken0);
        vm.prank(creator1);
        orderManager.cancelOrder(poolKey, posKey);
    }

    // L-07 Lacking setExecutablePositionsLimit Validation
    function test_setZeroAsExecutablePositionLimit() public {
        vm.expectRevert();
        orderManager.setExecutablePositionsLimit(0);
    }

    // L-08 Unnecessary Repeated Minting
    function test_unnecessaryRepeatedMinting() public {
        IPoolManager poolManager = IPoolManager(manager);
        uint256 balanceZero = poolManager.balanceOf(orderManagerAddr, currency0.toId());
        uint256 balanceOne = poolManager.balanceOf(orderManagerAddr, currency1.toId());
        console.log("Balance in token zero before create 1st order: ", balanceZero);
        console.log("Balance in token one before create 1st order: ", balanceOne);
        _createLimitOrder(creator1, true, 60, 3 ether);
        balanceZero = poolManager.balanceOf(orderManagerAddr, currency0.toId());
        balanceOne = poolManager.balanceOf(orderManagerAddr, currency1.toId());
        console.log("Balance in token zero after create 1st order: ", balanceZero);
        console.log("Balance in token one after create 1st order: ", balanceOne);

        BalanceDelta swapDelta1 = _swap(40, false, 3 ether);
        console.log("First swap amount in token zero: ", swapDelta1.amount0());
        console.log("First swap amount in token one: ", swapDelta1.amount1());
        BalanceDelta swapDelta2 = _swap(-10, true, 3 ether);
        console.log("Second swap amount in token zero: ", swapDelta2.amount0());
        console.log("Second swap amount in token one: ", swapDelta2.amount1());

        _createLimitOrder(creator1, true, 60, 3 ether);
        balanceZero = poolManager.balanceOf(orderManagerAddr, currency0.toId());
        balanceOne = poolManager.balanceOf(orderManagerAddr, currency1.toId());
        console.log("Balance in token zero after create 2nd order: ", balanceZero);
        console.log("Balance in token one after create 2nd order: ", balanceOne);

        assertApproxEqRel(uint256((uint128(-swapDelta1.amount1())) * 3 / 1000), balanceOne, 1e14);
        assertApproxEqRel(uint256((uint128(-swapDelta2.amount0())) * 3 / 1000), balanceZero, 1e14);
    }

    // L-09 Orders Can Be Made For Unconnected Pools
    function test_createOrdersOnUnconnectedPool() public {
        console.log("poolkey hooks address: ", address(poolKey.hooks));
        uint160 flags = uint160(Hooks.BEFORE_DONATE_FLAG);
        address hookAddress = address(flags);
        MockHooks mockHooks;
        mockHooks = MockHooks(hookAddress);
        (poolKey,) = initPool(currency0, currency1, mockHooks, 3000, TickMath.getSqrtPriceAtTick(-1));
        console.log("Mock hook address: ", address(poolKey.hooks));
        
        orderManager.setWhitelistedPool(poolKey.toId(), true);
        
        deal(Currency.unwrap(currency0), creator1, 1 ether);
        vm.startPrank(creator1);
        IERC20Minimal(Currency.unwrap(currency0)).approve(orderManagerAddr, 1 ether);
        vm.expectRevert();
        orderManager.createLimitOrder(true, 300, 1 ether, poolKey);
        vm.stopPrank();
    }

    // L-12 Incorrect getUserClaimableBalances Result
    function test_incorrect_getUserClaimableBalances() public {
        ILimitOrderManager.CreateOrderResult memory result = _createLimitOrder(creator2, true, 120, 2 ether);
        bytes32 posKey = _getPositionKey(result.bottomTick, result.topTick, result.isToken0);
        _swap(130, false, 4 ether);
        (
            ILimitOrderManager.ClaimableTokens memory claimable0,
            ILimitOrderManager.ClaimableTokens memory claimable1
        ) = getClaimableBalances(creator2, poolKey);
        
        result = _createLimitOrder(creator1, false, 60, 3 ether);

        _swap(70, true, 4 ether);
        (
            ILimitOrderManager.ClaimableTokens memory claimable0AfterSwap1,
            ILimitOrderManager.ClaimableTokens memory claimable1AfterSwap1
        ) = getClaimableBalances(creator2, poolKey);
        assertEq(claimable0.fees, claimable0AfterSwap1.fees);
        assertEq(claimable1.fees, claimable1AfterSwap1.fees);

        _swap(100, false, 4 ether);
        (
            ILimitOrderManager.ClaimableTokens memory claimable0AfterSwap2,
            ILimitOrderManager.ClaimableTokens memory claimable1AfterSwap2
        ) = getClaimableBalances(creator2, poolKey);
        assertEq(claimable0AfterSwap1.fees, claimable0AfterSwap2.fees);
        assertEq(claimable1AfterSwap1.fees, claimable1AfterSwap2.fees);

        _swap(-10, true, 10 ether);
        (, int24 currentTick,,) = StateLibrary.getSlot0(manager, poolId);
        assertEq(currentTick, -10);

        console.log("\n<<< Create -> Cancel >>>");
        result = _createLimitOrder(creator3, true, 120, 2 ether);
        posKey = _getPositionKey(result.bottomTick, result.topTick, result.isToken0);
        (claimable0, claimable1) = getClaimableBalances(creator3, poolKey);
        uint256 bal0Before = currency0.balanceOf(creator3);
        uint256 bal1Before = currency1.balanceOf(creator3);
        vm.prank(creator3);
        orderManager.cancelOrder(poolKey, posKey);
        uint256 bal0After = currency0.balanceOf(creator3);
        uint256 bal1After = currency1.balanceOf(creator3);
        assertApproxEqRel(claimable0.principal + claimable0.fees, bal0After - bal0Before, 1e10);

        console.log("\n<<< Create -> Swap -> Cancel >>>");
        result = _createLimitOrder(creator3, true, 120, 2 ether);
        posKey = _getPositionKey(result.bottomTick, result.topTick, result.isToken0);
        _swap(110, false, 10 ether);
        (claimable0, claimable1) = getClaimableBalances(creator3, poolKey);
        bal0Before = currency0.balanceOf(creator3);
        bal1Before = currency1.balanceOf(creator3);
        vm.prank(creator3);
        orderManager.cancelOrder(poolKey, posKey);
        bal0After = currency0.balanceOf(creator3);
        bal1After = currency1.balanceOf(creator3);
        assertApproxEqRel(claimable0.principal + claimable0.fees, bal0After - bal0Before, 1e10);
        
        console.log("\n<<< Create -> Swap -> Execute -> Cancel >>>");
        _swap(-10, true, 10 ether);
        result = _createLimitOrder(creator3, true, 120, 2 ether);
        posKey = _getPositionKey(result.bottomTick, result.topTick, result.isToken0);
        _swap(130, false, 10 ether);
        (claimable0, claimable1) = getClaimableBalances(creator3, poolKey);
        bal0Before = currency0.balanceOf(creator3);
        bal1Before = currency1.balanceOf(creator3);
        vm.prank(creator3);
        orderManager.cancelOrder(poolKey, posKey);
        bal0After = currency0.balanceOf(creator3);
        bal1After = currency1.balanceOf(creator3);
        assertApproxEqRel(claimable0.principal + claimable0.fees, bal0After - bal0Before, 1e10);
        
        console.log("\n<<< Create -> Swap -> Execute -> Claim >>>");
        _swap(-10, true, 10 ether);
        result = _createLimitOrder(creator3, true, 120, 2 ether);
        posKey = _getPositionKey(result.bottomTick, result.topTick, result.isToken0);
        _swap(130, false, 10 ether);
        (claimable0, claimable1) = getClaimableBalances(creator3, poolKey);
        bal0Before = currency0.balanceOf(creator3);
        bal1Before = currency1.balanceOf(creator3);
        orderManager.claimOrder(poolKey, posKey, creator3);
        bal0After = currency0.balanceOf(creator3);
        bal1After = currency1.balanceOf(creator3);
        assertApproxEqRel(claimable0.principal + claimable0.fees, bal0After - bal0Before, 1e10);
    }

    // L-21 Keeper Execution DoS'd
    function test_keeperExecution_DoS() public {
        orderManager.setExecutablePositionsLimit(2);
        orderManager.setKeeper(address(this), true);
        _createScaleOrder(creator1, true, 60, 360, 10 ether, 5, 1e18);
        _swap(400, false, 20 ether);

        bytes32 posKey = _getPositionKey(240, 300, true);
        ( , uint128 totalLiq, bool isActive, , ) = orderManager.positionState(poolId, posKey);
        console.log("Liquidity: ", totalLiq);
        console.log("Active: ", isActive);
        vm.prank(creator1);
        orderManager.cancelOrder(poolKey, posKey);
        ( , totalLiq, isActive, , ) = orderManager.positionState(poolId, posKey);
        console.log("Liquidity: ", totalLiq);
        console.log("Active: ", isActive);

        ILimitOrderManager.PositionTickRange[] memory waitingPositions = new ILimitOrderManager.PositionTickRange[](3);
        waitingPositions[0] = ILimitOrderManager.PositionTickRange({bottomTick: 180, topTick: 240, isToken0: true});
        waitingPositions[1] = ILimitOrderManager.PositionTickRange({bottomTick: 240, topTick: 300, isToken0: true});
        waitingPositions[2] = ILimitOrderManager.PositionTickRange({bottomTick: 300, topTick: 360, isToken0: true});

        orderManager.executeOrderByKeeper(poolKey, waitingPositions);
    }

    // L-23 Max Limit Can Prevent Scale Orders
    function test_wrong_MaxLimit_for_scaleOrders() public {
        vm.expectRevert();
        orderManager.setMaxOrderLimit(1);
    }

    // L-25 _executePosition Does Not Reset isWaitingKeeper
    function test_reset_iswaitingkeeper() public {
        orderManager.setExecutablePositionsLimit(2);
        _createScaleOrder(creator1, true, 60, 360, 5 ether, 5, 1e18);
        bytes32[] memory posKeys = new bytes32[](5);
        posKeys[0] = _getPositionKey(60, 120, true);
        posKeys[1] = _getPositionKey(120, 280, true);
        posKeys[2] = _getPositionKey(180, 240, true);
        posKeys[3] = _getPositionKey(240, 300, true);
        posKeys[4] = _getPositionKey(300, 360, true);
        bool isWaitingKeeper;
        _swap(400, false, 5 ether);
        console.log("\n<<< First swap to tick-400, so first 2 orders are executed and others are set as isWaitingKeeper.>>>");
        ( , , , isWaitingKeeper, ) = orderManager.positionState(poolId, posKeys[0]);
        assertEq(isWaitingKeeper, false);
        ( , , , isWaitingKeeper, ) = orderManager.positionState(poolId, posKeys[1]);
        assertEq(isWaitingKeeper, false);
        ( , , , isWaitingKeeper, ) = orderManager.positionState(poolId, posKeys[2]);
        assertEq(isWaitingKeeper, true);
        ( , , , isWaitingKeeper, ) = orderManager.positionState(poolId, posKeys[3]);
        assertEq(isWaitingKeeper, true);
        ( , , , isWaitingKeeper, ) = orderManager.positionState(poolId, posKeys[4]);
        assertEq(isWaitingKeeper, true);

        _swap(-10, true, 5 ether);

        _swap(400, false, 3 ether);
        console.log("\n<<< Second swap to tick-400, so next 2 orders are executed.>>>");
        ( , , , isWaitingKeeper, ) = orderManager.positionState(poolId, posKeys[0]);
        assertEq(isWaitingKeeper, false);
        ( , , , isWaitingKeeper, ) = orderManager.positionState(poolId, posKeys[1]);
        assertEq(isWaitingKeeper, false);
        ( , , , isWaitingKeeper, ) = orderManager.positionState(poolId, posKeys[2]);
        assertEq(isWaitingKeeper, false);
        ( , , , isWaitingKeeper, ) = orderManager.positionState(poolId, posKeys[3]);
        assertEq(isWaitingKeeper, false);
        ( , , , isWaitingKeeper, ) = orderManager.positionState(poolId, posKeys[4]);
        assertEq(isWaitingKeeper, true);
    }

    // L-28 Incorrect Current Nonce On Position
    function test_incorrectCurrentNonceOnPositionState() public {
        bytes32 baseKey = _getBaseKey(60, 120, true);
        _createLimitOrder(creator1, true, 120, 1 ether);
        uint256 poolNonce = orderManager.currentNonce(poolId, baseKey);
        bytes32 posKey = _getPositionKey(60, 120, true);
        console.log("pool nonce: ", poolNonce);
        ( , , , , uint256 posNonce) = orderManager.positionState(poolId, posKey);
        console.log("position nonce: ", posNonce);

        _swap(150, false, 2 ether);
        _swap(-10, true, 2 ether);

        _createLimitOrder(creator1, true, 120, 1 ether);
        poolNonce = orderManager.currentNonce(poolId, baseKey);
        posKey = _getPositionKey(60, 120, true);
        console.log("pool nonce: ", poolNonce);
        ( , , , , posNonce) = orderManager.positionState(poolId, posKey);
        console.log("position nonce: ", posNonce);

        _swap(150, false, 2 ether);
        _swap(-10, true, 2 ether);

        _createLimitOrder(creator1, true, 120, 1 ether);
        poolNonce = orderManager.currentNonce(poolId, baseKey);
        posKey = _getPositionKey(60, 120, true);
        console.log("pool nonce: ", poolNonce);
        ( , , , , posNonce) = orderManager.positionState(poolId, posKey);
        console.log("position nonce: ", posNonce);

        _swap(150, false, 2 ether);
        _swap(-10, true, 2 ether);

        _createLimitOrder(creator1, true, 120, 1 ether);
        poolNonce = orderManager.currentNonce(poolId, baseKey);
        posKey = _getPositionKey(60, 120, true);
        console.log("pool nonce: ", poolNonce);
        ( , , , , posNonce) = orderManager.positionState(poolId, posKey);
        console.log("position nonce: ", posNonce);
    }

    function _createLimitOrder(
        address _creator, 
        bool isToken0, 
        int24 targetTick, 
        uint256 amount
    ) internal returns (ILimitOrderManager.CreateOrderResult memory result) {
        Currency currency = isToken0 ? currency0 : currency1;
        deal(Currency.unwrap(currency), address(_creator), amount);
        vm.startPrank(_creator);
        IERC20Minimal(Currency.unwrap(currency)).approve(orderManagerAddr, amount);
        result = orderManager.createLimitOrder(isToken0, targetTick, amount, poolKey);
        vm.stopPrank();
    }
    
    // function _createRangeOrder(
    //     address _creator,
    //     bool isToken0,
    //     int24 bottomTick,
    //     int24 topTick,
    //     uint256 amount
    // ) internal returns (ILimitOrderManager.CreateOrderResult memory result) {
    //     Currency currency = isToken0 ? currency0 : currency1;
    //     deal(Currency.unwrap(currency), address(_creator), amount);
    //     vm.startPrank(_creator);
    //     IERC20Minimal(Currency.unwrap(currency)).approve(orderManagerAddr, amount);
    //     result = orderManager.createRangeOrder(isToken0, bottomTick, topTick, amount, poolKey);
    //     vm.stopPrank();
    // }

    function _createScaleOrder(
        address _creator,
        bool isToken0,
        int24 bottomTick,
        int24 topTick,
        uint256 totalAmount,
        uint256 totalOrders,
        uint256 sizeSkew
    ) internal returns (ILimitOrderManager.CreateOrderResult[] memory results) {
        Currency currency = isToken0 ? currency0 : currency1;
        deal(Currency.unwrap(currency), address(_creator), totalAmount);
        vm.startPrank(_creator);
        IERC20Minimal(Currency.unwrap(currency)).approve(orderManagerAddr, totalAmount);
        results = orderManager.createScaleOrders(isToken0, bottomTick, topTick, totalAmount, totalOrders, sizeSkew, poolKey);
        vm.stopPrank();
    }

    function _swap(int24 limitTick, bool zeroForOne, int256 amount) internal returns (BalanceDelta delta) {
        // Get the tick before swap
        (,int24 tickBeforeSwap,,) = StateLibrary.getSlot0(manager, poolId);
        
        uint160 priceLimit = TickMath.getSqrtPriceAtTick(limitTick);
        delta = swapRouter.swap(
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

    function _getBaseKey(int24 bottomTick, int24 topTick, bool isToken0) internal returns (bytes32 baseKey) {
        baseKey = bytes32(
            uint256(uint24(bottomTick)) << 232 |
            uint256(uint24(topTick)) << 208 |
            uint256(isToken0 ? 1 : 0)
        );
    }

    function _getPositionKey(int24 bottomTick, int24 topTick, bool isToken0) internal returns (bytes32 positionKey) {
        bytes32 baseKey = _getBaseKey(bottomTick, topTick, isToken0);
        uint256 currentNonce = orderManager.currentNonce(poolId, baseKey);

        positionKey = bytes32(
            uint256(uint24(bottomTick)) << 232 |
            uint256(uint24(topTick)) << 208 |
            uint256(currentNonce) << 8 |
            uint256(isToken0 ? 1 : 0)
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
        ILimitOrderManager.PositionInfo[] memory positions = orderManager.getUserPositions(user, poolId);
        
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