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
import "../src/TickLibrary.sol";

contract ComprehensiveTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    uint256 public HOOK_FEE_PERCENTAGE = 50000;
    uint256 public constant FEE_DENOMINATOR = 100000;
    uint256 internal constant Q128 = 1 << 128;
    LimitOrderHook hook;
    ILimitOrderManager limitOrderManager;
    address public treasury;
    PoolKey poolKey;
    PoolId poolId;
    address public creator1 = vm.addr(1);
    address public creator2 = vm.addr(2);
    address public creator3 = vm.addr(3);

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
        (poolKey,) = initPool(currency0, currency1, hook, 3000, TickMath.getSqrtPriceAtTick(-1));
        poolId = poolKey.toId();
        orderManager.setWhitelistedPool(poolKey.toId(), true);
        
        // Approve tokens to manager
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(limitOrderManager), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(limitOrderManager), type(uint256).max);
    }

    // function test_findOverlappings() public {
    //     // 1. Find overlapping positions correctly
    //     // 2. Break iteration correctly

    //     // Initialize position list for testing
    //     for(int24 i = 1 ; i <= 100 ; i++) {
    //         _createLimitOrder(creator1, true, (i * poolKey.tickSpacing), 0.1 ether);
    //     }

    //     ILimitOrderManager.PositionTickRange[] memory positionList = limitOrderManager.getPositionList(poolId, true);
    //     assertEq(positionList.length, 100);
    //     assertEq(positionList[99].topTick, 6000); // last order's top tick is 6000

    //     (, int24 currentTick,,) = StateLibrary.getSlot0(manager, poolId);
    //     _swap(currentTick + poolKey.tickSpacing * 10, false, 1 ether);
    //     (, currentTick,,) = StateLibrary.getSlot0(manager, poolId);

    // }

    function test_create_many_ScaleOrders() public {
        for(int24 i = 1 ; i <= 100 ; i++) {
            _createLimitOrder(creator1, true, i * poolKey.tickSpacing, 0.001 ether);
        }
        for (int24 i = 0; i < 10; i++) {
            (, int24 currentTick,,) = StateLibrary.getSlot0(manager, poolId);
            _swap(currentTick + poolKey.tickSpacing * 1000, false, 1 ether);
            (, currentTick,,) = StateLibrary.getSlot0(manager, poolId);
        }
    }

    function test_orderCanceling_no_remove_liquidity() public {
        ILimitOrderManager.CreateOrderResult memory result = _createLimitOrder(creator1, true, 60, 1 ether);
        bytes32 baseKey = bytes32(
            uint256(uint24(result.bottomTick)) << 232 |
            uint256(uint24(result.topTick)) << 208 |
            uint256(result.isToken0 ? 1 : 0)
        );

        // Generate full position key with nonce
        bytes32 positionKey = bytes32(
            uint256(uint24(result.bottomTick)) << 232 |
            uint256(uint24(result.topTick)) << 208 |
            uint256(limitOrderManager.currentNonce(poolId, baseKey)) << 8 |
            uint256(result.isToken0 ? 1 : 0)
        );

        ( , uint128 positionLiquidity, , , ) = limitOrderManager.positionState(poolId, positionKey);
        ILimitOrderManager.PositionInfo[] memory userPositions = limitOrderManager.getUserPositions(creator1, poolId);
        // Get liquidity for this position
        (uint128 liquidity, , ) = StateLibrary.getPositionInfo(
            manager,
            poolId,
            address(limitOrderManager),
            result.bottomTick,
            result.topTick,
            bytes32(0)
        );
        assertEq(positionLiquidity, liquidity);
        assertEq(positionLiquidity, userPositions[0].liquidity);

        vm.prank(creator1);
        limitOrderManager.cancelOrder(poolKey, positionKey);
        ( , positionLiquidity, , , ) = limitOrderManager.positionState(poolId, positionKey);
        userPositions = limitOrderManager.getUserPositions(creator1, poolId);
        (liquidity, , ) = StateLibrary.getPositionInfo(
            manager,
            poolId,
            address(limitOrderManager),
            result.bottomTick,
            result.topTick,
            bytes32(0)
        );
        assertEq(positionLiquidity, liquidity);
        assertEq(0, userPositions.length);
    }

    // function test_createOrder_on_waitingPosition() public {
    //     deal(Currency.unwrap(currency0), address(this), 100 ether);
    //     // Create 6 orders from tick 0 to tick 360
    //     ILimitOrderManager.CreateOrderResult[] memory result = limitOrderManager.createScaleOrders(true, 0, 360, 1 ether, 6, 1e18, poolKey);

    //     ILimitOrderManager.PositionTickRange[] memory positionList = limitOrderManager.getPositionList(poolId, true);
    //     assertEq(positionList.length, 6);

    //     // Swap from tick -1 to tick 380, so orders placed from tick-0 to tick-360 are executed or waiting for keeper
    //     _swap(380, false, 1 ether);
    //     (, int24 currentTick,,) = StateLibrary.getSlot0(manager, poolId);
    //     assertGt(currentTick, 360);
    //     positionList = limitOrderManager.getPositionList(poolId, true);
    //     assertEq(positionList.length, 1); // Among 6 orders, 5 orders are executed by plugin and remained only 1 order

    //     // Swap back from tick 380 to tick 200
    //     _swap(200, true, 1 ether);
    //     (, currentTick,,) = StateLibrary.getSlot0(manager, poolId);
    //     assertLt(currentTick, 240);

    //     // Create 3 orders from tick 240 to tick 420
    //     vm.expectRevert();
    //     result = limitOrderManager.createScaleOrders(true, 240, 420, 1 ether, 3, 1e18, poolKey);
    // }

    // function test_incorrectPositionsRemoved_executeOrderByKeeper() public {
    //     _createScaleOrder(creator1, true, 0, 300, 0.5 ether, 5, 1e18);
    //     _createLimitOrder(creator1, true, 240, 0.4 ether);
    //     _createLimitOrder(creator2, true, 60, 0.1 ether);
    //     _createLimitOrder(creator2, true, 120, 0.2 ether);
    //     _createLimitOrder(creator3, true, 240, 0.1 ether);
    //     _createLimitOrder(creator3, true, 180, 0.3 ether);

    //     // check position contributors
    //     {
    //         bytes32 positionKey = _getPositionKey(0, 60, true);
    //         uint256 contributorsAmount = limitOrderManager.getPositionContributorsLength(poolId, positionKey);
    //         assertEq(contributorsAmount, 2);
    //         address contributor = limitOrderManager.getPositionContributor(poolId, positionKey, 0);
    //         assertEq(contributor, creator1);
    //         contributor = limitOrderManager.getPositionContributor(poolId, positionKey, 1);
    //         assertEq(contributor, creator2);

    //         positionKey = _getPositionKey(60, 120, true);
    //         contributorsAmount = limitOrderManager.getPositionContributorsLength(poolId, positionKey);
    //         assertEq(contributorsAmount, 2);
    //         contributor = limitOrderManager.getPositionContributor(poolId, positionKey, 0);
    //         assertEq(contributor, creator1);

    //         positionKey = _getPositionKey(180, 240, true);
    //         contributorsAmount = limitOrderManager.getPositionContributorsLength(poolId, positionKey);
    //         assertEq(contributorsAmount, 2);
    //         contributor = limitOrderManager.getPositionContributor(poolId, positionKey, 0);
    //         assertEq(contributor, creator1);
    //         contributor = limitOrderManager.getPositionContributor(poolId, positionKey, 1);
    //         assertEq(contributor, creator3);

    //         positionKey = _getPositionKey(0, 120, true);
    //         contributorsAmount = limitOrderManager.getPositionContributorsLength(poolId, positionKey);
    //         assertEq(contributorsAmount, 0);

    //         positionKey = _getPositionKey(240, 300, true);
    //         contributorsAmount = limitOrderManager.getPositionContributorsLength(poolId, positionKey);
    //         assertEq(contributorsAmount, 1);
    //         contributor = limitOrderManager.getPositionContributor(poolId, positionKey, 0);
    //         assertEq(contributor, creator1);
    //     }

    //     // check user positions
    //     {
    //         ILimitOrderManager.PositionInfo[] memory positions = limitOrderManager.getUserPositions(creator1, poolId);
    //         assertEq(positions.length, 5);
    //         positions = limitOrderManager.getUserPositions(creator2, poolId);
    //         assertEq(positions.length, 2);
    //         positions = limitOrderManager.getUserPositions(creator3, poolId);
    //         assertEq(positions.length, 2);
    //     }

    //     // check position tick range list
    //     {
    //         ILimitOrderManager.PositionTickRange[] memory posTickRangeList = limitOrderManager.getPositionList(poolId, true);
    //         assertEq(posTickRangeList[0].bottomTick, 0); assertEq(posTickRangeList[0].topTick, 60); 
    //         assertEq(posTickRangeList[1].bottomTick, 60); assertEq(posTickRangeList[1].topTick, 120); 
    //         assertEq(posTickRangeList[2].bottomTick, 120); assertEq(posTickRangeList[2].topTick, 180); 
    //         assertEq(posTickRangeList[3].bottomTick, 180); assertEq(posTickRangeList[3].topTick, 240); 
    //         assertEq(posTickRangeList[4].bottomTick, 240); assertEq(posTickRangeList[4].topTick, 300); 
    //     }

    //     // Swap from tick -1 to tick 310, so 5 positions are passed
    //     _swap(310, false, 2 ether);

    //     // check position isWaitingKeeper state
    //     {
    //        bytes32 posKey = _getPositionKey(0, 60, true); 
    //        ( , , , bool isWaitingKeeper, ) = limitOrderManager.positionState(poolId, posKey);
    //        assertEq(isWaitingKeeper, false);

    //        posKey = _getPositionKey(60, 120, true); 
    //        ( , , , isWaitingKeeper, ) = limitOrderManager.positionState(poolId, posKey);
    //        assertEq(isWaitingKeeper, false);

    //        posKey = _getPositionKey(120, 180, true); 
    //        ( , , , isWaitingKeeper, ) = limitOrderManager.positionState(poolId, posKey);
    //        assertEq(isWaitingKeeper, false);

    //        posKey = _getPositionKey(180, 240, true); 
    //        ( , , , isWaitingKeeper, ) = limitOrderManager.positionState(poolId, posKey);
    //        assertEq(isWaitingKeeper, false);

    //        posKey = _getPositionKey(240, 300, true); 
    //        ( , , , isWaitingKeeper, ) = limitOrderManager.positionState(poolId, posKey);
    //        assertEq(isWaitingKeeper, false);
    //     }
    // }

    function test_transfer_accidentally_native_token() public {
        vm.deal(creator1, 100 ether);
        // create orders in token zero and accidentally transfer native token together
        deal(Currency.unwrap(currency0), address(creator1), 1 ether);
        vm.startPrank(creator1);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(limitOrderManager), 1 ether);
        vm.expectRevert();
        // ILimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder{value: 0.1 ether}(true, true, 301, 1 ether, poolKey);
        ILimitOrderManager.CreateOrderResult memory result = limitOrderManager.createLimitOrder{value: 0.1 ether}(true, 301, 1 ether, poolKey);
        vm.stopPrank();

        // create orders in token one and accidentally transfer native token together
        deal(Currency.unwrap(currency1), address(creator1), 1 ether);
        vm.startPrank(creator1);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(limitOrderManager), 1 ether);
        vm.expectRevert();
        // result = limitOrderManager.createLimitOrder{value: 0.1 ether}(false, true, -301, 1 ether, poolKey);
        result = limitOrderManager.createLimitOrder{value: 0.1 ether}(false, -301, 1 ether, poolKey);
        vm.stopPrank();
    }

    function test_wrongful_liquidity_burn() public {
        _createLimitOrder(creator1, true, 120, 1 ether);
        _swap(180, false, 2 ether);
        _swap(0, true, 2 ether);
        _createLimitOrder(creator2, true, 120, 1 ether);
        bytes32 positionKey = _getPositionKey(60, 120, true);
        vm.startPrank(creator1);
        vm.expectRevert();
        limitOrderManager.cancelOrder(poolKey, positionKey);
        vm.stopPrank();

        vm.prank(creator2);
        limitOrderManager.cancelOrder(poolKey, positionKey);
    }

    // function _createLimitOrder(
    //     address _creator, 
    //     bool isToken0, 
    //     bool isRange, 
    //     int24 targetTick, 
    //     uint256 amount
    // ) internal returns (ILimitOrderManager.CreateOrderResult memory result) {
    //     Currency currency = isToken0 ? currency0 : currency1;
    //     deal(Currency.unwrap(currency), address(_creator), amount);
    //     vm.startPrank(_creator);
    //     IERC20Minimal(Currency.unwrap(currency)).approve(address(limitOrderManager), amount);
    //     result = limitOrderManager.createLimitOrder(isToken0, isRange, targetTick, amount, poolKey);
    //     vm.stopPrank();
    // }
    function _createLimitOrder(
        address _creator, 
        bool isToken0, 
        // bool isRange, 
        int24 targetTick, 
        uint256 amount
    ) internal returns (ILimitOrderManager.CreateOrderResult memory result) {
        Currency currency = isToken0 ? currency0 : currency1;
        deal(Currency.unwrap(currency), address(_creator), amount);
        vm.startPrank(_creator);
        IERC20Minimal(Currency.unwrap(currency)).approve(address(limitOrderManager), amount);
        // result = limitOrderManager.createLimitOrder(isToken0, isRange, targetTick, amount, poolKey);
        result = limitOrderManager.createLimitOrder(isToken0, targetTick, amount, poolKey);
        vm.stopPrank();
    }

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
        IERC20Minimal(Currency.unwrap(currency)).approve(address(limitOrderManager), totalAmount);
        results = limitOrderManager.createScaleOrders(isToken0, bottomTick, topTick, totalAmount, totalOrders, sizeSkew, poolKey);
        vm.stopPrank();
    }

    function _swap(int24 limitTick, bool zeroForOne, int256 amount) internal {
        uint160 priceLimit = TickMath.getSqrtPriceAtTick(limitTick);
        swapRouter.swap(
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
    }

    function _getPositionKey(int24 bottomTick, int24 topTick, bool isToken0) internal returns (bytes32 positionKey) {
        bytes32 baseKey = bytes32(
            uint256(uint24(bottomTick)) << 232 |
            uint256(uint24(topTick)) << 208 |
            uint256(isToken0 ? 1 : 0)
        );

        uint256 currentNonce = limitOrderManager.currentNonce(poolId, baseKey);

        positionKey = bytes32(
            uint256(uint24(bottomTick)) << 232 |
            uint256(uint24(topTick)) << 208 |
            uint256(currentNonce) << 8 |
            uint256(isToken0 ? 1 : 0)
        );
    }
}