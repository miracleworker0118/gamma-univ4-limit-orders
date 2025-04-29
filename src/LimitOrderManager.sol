// SPDX-License-Identifier: BSL
pragma solidity ^0.8.24;

import {ILimitOrderManager} from "./ILimitOrderManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import "./PositionManagement.sol";
import "./TickLibrary.sol";
import "./CallbackHandler.sol";
import "forge-std/console.sol";
import {TickBitmap} from "v4-core/libraries/TickBitmap.sol";
import {BitMath} from "v4-core/libraries/BitMath.sol";

/// @title LimitOrderManager
/// @notice Manages limit orders for Uniswap v4 pools
/// @dev Handles creation, execution, and cancellation of limit orders with fee collection and position tracking
contract LimitOrderManager is ILimitOrderManager, IUnlockCallback, Ownable, ReentrancyGuard, Pausable {
    using CurrencySettler for Currency;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using SafeCast for *;
    using TickLibrary for int24;
    using CallbackHandler for CallbackHandler.CallbackState;
    using SafeERC20 for IERC20;

    // Pool manager reference
    IPoolManager public immutable poolManager;
    
    // Hook address
    address public hook;

    // Constants
    uint256 internal constant Q128 = 1 << 128;
    uint256 public constant FEE_DENOMINATOR = 100000;
    BalanceDelta public constant ZERO_DELTA = BalanceDelta.wrap(0);

    // State variables from original contract
    CallbackHandler.CallbackState private callbackState;
    address public override treasury;
    uint256 public override executablePositionsLimit = 75;
    uint256 public hook_fee_percentage = 50000;
    uint24 public maxOrderLimit = 100; // Default to 100 orders
    mapping(Currency => uint256) public override minAmount;
    mapping(address => bool) public override isKeeper;
    

    // Original state mappings
    mapping(PoolId => bool) public whitelistedPool;
    mapping(PoolId => mapping(bytes32 => EnumerableSet.AddressSet)) private positionContributors;
    mapping(PoolId => mapping(bytes32 => mapping(address => UserPosition))) public userPositions;
    mapping(PoolId => mapping(bytes32 => uint256)) public override currentNonce;

    mapping(PoolId => mapping(int16 => uint256)) public token0TickBitmap;
    mapping(PoolId => mapping(int16 => uint256)) public token1TickBitmap;
    mapping(PoolId => mapping(int24 => bytes32)) public token0PositionAtTick;
    mapping(PoolId => mapping(int24 => bytes32)) public token1PositionAtTick;

    mapping(PoolId => mapping(bytes32 => PositionState)) public positionState;
    mapping(address => mapping(PoolId => EnumerableSet.Bytes32Set)) private userPositionKeys;


    constructor(address _poolManagerAddr, address _treasury, address _owner) Ownable(_owner) {
        require(_treasury != address(0) && _poolManagerAddr != address(0));
            treasury = _treasury;
            poolManager = IPoolManager(_poolManagerAddr);

            // Initialize callback state
            callbackState.poolManager = poolManager;
            callbackState.treasury = _treasury;
            callbackState.feeDenominator = FEE_DENOMINATOR;
            callbackState.hookFeePercentage = hook_fee_percentage;
        }

// =========== Create Order Functions ===========
    /// @notice Creates a single limit order in a specified pool
    /// @param isToken0 True if order is for token0, false for token1
    /// @param targetTick The target tick price for the order
    /// @param amount The amount of tokens to use for the order
    /// @param key The pool key identifying the specific pool
    /// @return result Order creation result
    /// @dev Validates parameters and transfers tokens from user before creating order
    function createLimitOrder(
        bool isToken0,
        int24 targetTick,
        uint256 amount,
        PoolKey calldata key
    ) external payable override returns (CreateOrderResult memory) {

        
        // Get current tick for validation
        PoolId poolId = key.toId();


        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);

        // For limit orders, target tick is either lower or upper based on direction
        (int24 bottomTick, int24 topTick) = TickLibrary.getValidTickRange(
            currentTick,
            targetTick,
            key.tickSpacing,
            isToken0
        );

        ILimitOrderManager.OrderInfo[] memory orders = new ILimitOrderManager.OrderInfo[](1);
        orders[0] = ILimitOrderManager.OrderInfo({
            bottomTick: bottomTick,
            topTick: topTick,
            amount: 0,
            liquidity: 0
        });
        
        CreateOrderResult[] memory results = _createOrder(orders, isToken0, amount, 1, 0, key);
        return results[0]; // Return just the first result since it's a single order
    }


    /// @notice Creates multiple scaled limit orders across a price range
    /// @param isToken0 True if orders are for token0, false for token1
    /// @param bottomTick The lower tick bound of the order range
    /// @param topTick The upper tick bound of the order range
    /// @param totalAmount Total amount of tokens to distribute across orders
    /// @param totalOrders Number of orders to create
    /// @param sizeSkew Skew factor for order size distribution (1 for equal distribution)
    /// @param key The pool key identifying the specific pool
    /// @return results containing details of all created orders
    /// @dev Orders are distributed according to the sizeSkew parameter
    function createScaleOrders(
        bool isToken0,
        int24 bottomTick,
        int24 topTick,
        uint256 totalAmount,
        uint256 totalOrders,
        uint256 sizeSkew,
        PoolKey calldata key
    ) external payable returns (CreateOrderResult[] memory results) {
        // Get current tick for validation
        PoolId poolId = key.toId();

        (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);

        require(totalOrders <= maxOrderLimit);
        ILimitOrderManager.OrderInfo[] memory orders = 
            TickLibrary.validateAndPrepareScaleOrders(bottomTick, topTick, currentTick, isToken0, totalOrders, sizeSkew, key.tickSpacing);
        
        results = _createOrder(orders, isToken0, totalAmount, totalOrders, sizeSkew, key);
    }

    /**
     * @notice Internal function to create one or more limit orders with specified parameters
     * @dev Handles the core logic of order creation
     * @param orders Array of OrderInfo structs containing initial order parameters
     * @param isToken0 True if orders are for token0, false for token1
     * @param totalAmount Total amount of tokens to be used across all orders
     * @param totalOrders Number of orders to create (used for scale calculations)
     * @param sizeSkew Distribution factor for order sizes (0 for equal distribution)
     * @param key Pool key identifying the specific Uniswap V4 pool
     * @return results Array of CreateOrderResult structs containing created order details
     */
    function _createOrder(
        ILimitOrderManager.OrderInfo[] memory orders,
        bool isToken0,
        uint256 totalAmount,
        uint256 totalOrders,
        uint256 sizeSkew,
        PoolKey calldata key
    ) internal whenNotPaused returns (CreateOrderResult[] memory results) {
        require(address(key.hooks) == hook);
        require(totalAmount != 0);
        PoolId poolId = key.toId();
        if (!whitelistedPool[poolId]) revert NotWhitelistedPool();
        orders = PositionManagement.calculateOrderSizes(orders, isToken0, totalAmount, totalOrders, sizeSkew);
        require(
            PositionManagement.validateScaleOrderSizes(orders, totalAmount, minAmount[isToken0 ? key.currency0 : key.currency1])
        );
        // PositionManagement.validateScaleOrderSizes(orders, totalAmount, minAmount[isToken0 ? key.currency0 : key.currency1]);
        _handleTokenTransfer(isToken0, totalAmount, key);
        results = new CreateOrderResult[](orders.length);

        BalanceDelta[] memory feeDeltas = abi.decode(
            poolManager.unlock(abi.encode(
                UnlockCallbackData({
                    callbackType: CallbackType.CREATE_ORDERS,
                    data: abi.encode(CreateOrdersCallbackData({key: key, orders: orders, isToken0: isToken0, orderCreator: msg.sender}))
                })
            )),
            (BalanceDelta[])
        );

        bytes32 positionKey;
        OrderInfo memory order;
        for (uint256 i; i < orders.length; i++) {
            order = orders[i];
            (, positionKey) = PositionManagement.getPositionKeys(currentNonce, poolId, order.bottomTick, order.topTick, isToken0);
            require(!positionState[poolId][positionKey].isWaitingKeeper);
            _retrackPositionFee(poolId, positionKey, feeDeltas[i]);
            
            if(!positionState[poolId][positionKey].isActive) {
                positionState[poolId][positionKey].isActive = true;
                bytes32 baseKey = bytes32(
                    uint256(uint24(order.bottomTick)) << 232 |
                    uint256(uint24(order.topTick)) << 208 |
                    uint256(isToken0 ? 1 : 0)
                );
                positionState[poolId][positionKey].currentNonce = currentNonce[poolId][baseKey];
                
                // Get the executable tick (the tick where the order will be executed)
                int24 executableTick = isToken0 ? order.topTick : order.bottomTick;
                // console.log("executableTick:", executableTick);
                
                // Add position to bitmap-based storage
                PositionManagement.addPositionToTick(
                    isToken0 ? token0PositionAtTick : token1PositionAtTick,
                    isToken0 ? token0TickBitmap : token1TickBitmap,
                    key,
                    executableTick,
                    positionKey
                );
            }   

            _updateUserPosition(poolId, positionKey, order.liquidity, msg.sender);

            results[i].usedAmount = order.amount;
            results[i].isToken0 = isToken0;
            results[i].bottomTick = order.bottomTick;
            results[i].topTick = order.topTick;
            emit OrderCreated(msg.sender, poolId, positionKey);
        }

        return results;
    }

// =========== Cancel Order Functions ===========
    /// @notice Cancels a single limit order position
    /// @param key The pool key identifying the specific Uniswap V4 pool
    /// @param positionKey The unique identifier of the position to cancel
    function cancelOrder(PoolKey calldata key, bytes32 positionKey) external override nonReentrant{
        _cancelOrder(key, positionKey, msg.sender);
    }

    /// @notice Cancels multiple limit order positions in a batch
    /// @dev Uses pagination to handle large numbers of orders
    /// @param key The pool key identifying the specific Uniswap V4 pool
    /// @param offset Starting position in the user's position array
    /// @param limit Maximum number of positions to process in this call
    /// @return canceledCount Number of positions successfully canceled
    function cancelBatchOrders(
        PoolKey calldata key,
        uint256 offset,             
        uint256 limit
    ) external override nonReentrant returns (uint256 canceledCount) {
        PoolId poolId = key.toId();
        EnumerableSet.Bytes32Set storage userKeys = userPositionKeys[msg.sender][poolId];
        
        // Validate offset
        if (offset >= userKeys.length()) {
            return 0;
        }
        
        // Calculate end index
        uint256 endIndex = (offset + limit > userKeys.length()) ? 
            userKeys.length() : 
            offset + limit;
        
        // Process each key in the batch 
        uint256 i = endIndex;
        while (i > offset) {
            i--; // Decrement first to avoid underflow
            
            if (i < userKeys.length()) { // Double check index is still valid
                bytes32 positionKey = userKeys.at(i);
                uint128 liquidity = userPositions[poolId][positionKey][msg.sender].liquidity;
                
                if (liquidity > 0) {
                    _cancelOrder(key, positionKey, msg.sender);
                    canceledCount++;
                }
            }
        }
        
        return canceledCount;
    }

    /// @notice Emergency function to cancel orders on behalf of a user
    /// @dev Can only be called by the contract owner in emergency situations
    /// @param key The pool key identifying the specific Uniswap V4 pool
    /// @param user The address of the user whose orders will be canceled
    /// @param offset Starting position in the user's position array
    /// @param limit Maximum number of positions to process in this call
    /// @return canceledCount Number of positions successfully canceled
    function emergencyCancelOrders(
        PoolKey calldata key,
        address user,
        uint256 offset,             
        uint256 limit
    ) external returns (uint256 canceledCount) {
        require(user != address(0));
        require(isKeeper[msg.sender]);
        
        PoolId poolId = key.toId();
        EnumerableSet.Bytes32Set storage userKeys = userPositionKeys[user][poolId];
        
        // Validate offset
        if (offset >= userKeys.length()) {
            return 0;
        }
        
        // Calculate end index
        uint256 endIndex = (offset + limit > userKeys.length()) ? 
            userKeys.length() : 
            offset + limit;
        
        // Process each key in the batch
        uint256 i = endIndex;
        while (i > offset) {
            i--; // Decrement first to avoid underflow
            
            if (i < userKeys.length()) { // Double check index is still valid
                bytes32 positionKey = userKeys.at(i);
                uint128 liquidity = userPositions[poolId][positionKey][user].liquidity;
                
                if (liquidity > 0) {
                    _cancelOrder(key, positionKey, user);
                    canceledCount++;
                }
            }
        }
        
        return canceledCount;
    }

    /// @notice Internal function to handle the cancellation of a limit order
    /// @dev Handles both cancellation and claiming in a single transaction
    /// @param key The pool key identifying the specific Uniswap V4 pool
    /// @param positionKey The unique identifier of the position to cancel
    /// @param user The address of the position owner
    function _cancelOrder(
        PoolKey calldata key,
        bytes32 positionKey,
        address user
    ) internal {
        PoolId poolId = key.toId();

        // Early return for claimable balance
        if(userPositions[poolId][positionKey][user].claimablePrincipal != ZERO_DELTA || !positionState[poolId][positionKey].isActive) {
            _claimOrder(key, positionKey, user);
            return;
        }

        // Get position info 
        (int24 bottomTick, int24 topTick, bool isToken0, ) = _decodePositionKey(positionKey);
        
        // Store user's liquidity in a local variable to avoid deep storage access multiple times
        uint128 userLiquidity = userPositions[poolId][positionKey][user].liquidity;
        
        // Cancel order through pool manager
        (BalanceDelta callerDelta, BalanceDelta feeDelta) = abi.decode(
            poolManager.unlock(
                abi.encode(
                    UnlockCallbackData({
                        callbackType: CallbackType.CANCEL_ORDER,
                        data: abi.encode(
                            CancelOrderCallbackData({
                                key: key,
                                bottomTick: bottomTick,
                                topTick: topTick,
                                liquidity: userLiquidity,
                                user: user
                            })
                        )
                    })
                )
            ),
            (BalanceDelta, BalanceDelta)
        );

        _retrackPositionFee(poolId, positionKey, feeDelta);
        userPositions[poolId][positionKey][user].claimablePrincipal = callerDelta - feeDelta;
        positionState[poolId][positionKey].totalLiquidity -= userLiquidity;

        // Calculate executable tick here instead of earlier to reduce stack usage
        int24 executableTick = isToken0 ? topTick : bottomTick;
        
        // Handle position removal
        _handlePositionRemoval(poolId, positionKey, user, key, isToken0, executableTick);

        // Emit event for canceled order
        emit OrderCanceled(user, poolId, positionKey);
    }

    /// @notice Updated helper function
    function _handlePositionRemoval(
        PoolId poolId,
        bytes32 positionKey,
        address user,
        PoolKey calldata key,
        bool isToken0,
        int24 executableTick
    ) internal {
        // Claim tokens
        _claimOrder(key, positionKey, user);
        
        // Remove from contributors list
        positionContributors[poolId][positionKey].remove(user);
        
        // If no contributors left, completely remove the position
        if(positionContributors[poolId][positionKey].length() == 0) {
            positionState[poolId][positionKey].isActive = false;
            positionState[poolId][positionKey].isWaitingKeeper = false;
            
            // Remove from bitmap and position storage
            PositionManagement.removePositionFromTick(
                isToken0 ? token0PositionAtTick : token1PositionAtTick,
                isToken0 ? token0TickBitmap : token1TickBitmap,
                key,
                executableTick
            );
        }
    }

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

    /// @notice Allows claiming tokens from a canceled or executed limit order
    /// @param key The pool key identifying the specific Uniswap V4 pool
    /// @param positionKey The unique identifier of the position to claim
    /// @param user The address that will receive the claimed tokens
    function claimOrder(PoolKey calldata key, bytes32 positionKey, address user) nonReentrant external {
        _claimOrder(key, positionKey, user);
    }

    /// @notice Batch claims multiple orders that were executed or canceled
    /// @dev Uses pagination to handle large numbers of orders
    /// @param key The pool key identifying the specific Uniswap V4 pool
    /// @param offset Starting position in the user's position array
    /// @param limit Maximum number of positions to process in this call
    /// @return claimedCount Number of positions successfully claimed
    function claimBatchOrders(
        PoolKey calldata key,
        uint256 offset,             
        uint256 limit
    ) external nonReentrant returns (uint256 claimedCount) {
        PoolId poolId = key.toId();
        EnumerableSet.Bytes32Set storage userKeys = userPositionKeys[msg.sender][poolId];
        
        // Validate offset
        if (offset >= userKeys.length()) {
            return 0;
        }
        
        // Calculate end index
        uint256 endIndex = (offset + limit > userKeys.length()) ? 
            userKeys.length() : 
            offset + limit;
        
        // Process each key in the batch 
        uint256 i = endIndex;
        while (i > offset) {
            i--; // Decrement first to avoid underflow
            
            if (i < userKeys.length()) { // Double check index is still valid
                bytes32 positionKey = userKeys.at(i);
                UserPosition storage position = userPositions[poolId][positionKey][msg.sender];
                
                // Check if position is claimable
                if (position.liquidity > 0 && 
                   (position.claimablePrincipal != ZERO_DELTA || !positionState[poolId][positionKey].isActive)) {
                    _claimOrder(key, positionKey, msg.sender);
                    claimedCount++;
                }
            }
        }
        
        return claimedCount;
    }

    /// @notice Internal function to process claiming of tokens from a position
    /// @dev Calculates pending fees, transfers tokens to user, and cleans up position state
    /// @param key The pool key identifying the specific Uniswap V4 pool
    /// @param positionKey The unique identifier of the position to claim
    /// @param user The address that will receive the claimed tokens
    function _claimOrder(PoolKey calldata key, bytes32 positionKey, address user) internal {
        // Get pool ID and position data directly
        PoolId poolId = key.toId();
        
        // Check requirements
        require(userPositions[poolId][positionKey][user].liquidity > 0);
        require(userPositions[poolId][positionKey][user].claimablePrincipal != ZERO_DELTA ||!positionState[poolId][positionKey].isActive);
        
        // Get user position (keep this as storage reference since it's used multiple times)
        UserPosition storage position = userPositions[poolId][positionKey][user];

        // If position isn't active, calculate the claimable principal
        if (!positionState[poolId][positionKey].isActive) {
            position.claimablePrincipal = PositionManagement.getBalanceDelta(positionKey, position.liquidity);
        }

        // Update fees if needed
        if (position.liquidity != 0) {
            BalanceDelta feeDiff = positionState[poolId][positionKey].feePerLiquidity - position.lastFeePerLiquidity;
            int128 liq = int128(position.liquidity);
            BalanceDelta pendingFees = position.fees + PositionManagement.calculateScaledUserFee(feeDiff, uint128(liq));
            
            // Only update if different
            if (!(pendingFees == position.fees)) {
                position.fees = pendingFees;
            }
        }
        
        // Update the fee checkpoint
        position.lastFeePerLiquidity = positionState[poolId][positionKey].feePerLiquidity;

        // Store the claimable values before clearing
        BalanceDelta principal = position.claimablePrincipal;
        BalanceDelta fees = position.fees;
        
        // Clear user position data
        delete userPositions[poolId][positionKey][user];
        
        // Remove from position keys mapping
        userPositionKeys[user][poolId].remove(positionKey);
        
        // Execute the claim via pool manager unlock
        poolManager.unlock(
            abi.encode(
                UnlockCallbackData({
                    callbackType: CallbackType.CLAIM_ORDER,
                    data: abi.encode(
                        ClaimOrderCallbackData({
                            principal: principal,
                            fees: fees,
                            key: key, 
                            user: user
                        })
                    )
                })
            )
        );

        // Emit event (inline position key decoding)
        emit LimitOrderClaimed(poolId, user, int24(uint24(uint256(positionKey) >> 232)), int24(uint24(uint256(positionKey) >> 208)));
    }

    /**
     * @notice Executes limit orders that have been triggered by price movements
     * @dev Processes overlapping positions up to limit. Excess positions marked for keeper execution
     * @param key The pool key identifying the specific pool 
     * @param tickBeforeSwap The tick price before the swap started
     * @param tickAfterSwap The tick price after the swap completed
     * @param zeroForOne The direction of the swap (true for token0 to token1)
     */
    function executeOrder(
        PoolKey calldata key,
        int24 tickBeforeSwap,
        int24 tickAfterSwap,
        bool zeroForOne
    ) external override {
        // Validate caller and state
        require(msg.sender == hook);
        require(executablePositionsLimit != 0);
        
        PoolId poolId = key.toId();
        
        // Find executable positions
        int24[] memory executableTicks = _findOverlappingPositions(
            poolId, 
            tickBeforeSwap, 
            tickAfterSwap, 
            zeroForOne,
            key.tickSpacing
        );
        
        // Debug logging
        // console.log("tickBeforeSwap:", tickBeforeSwap);
        // console.log("tickAfterSwap:", tickAfterSwap);
        // console.log("zeroForOne:", zeroForOne);
        // console.log("executableTicks.length:", executableTicks.length);
        
        // Early return if no positions to execute
        if(executableTicks.length == 0) return;
        
        // Determine how many positions to execute in this transaction
        uint256 executableCount = executableTicks.length;
        // bool hasLeftoverPositions = executableCount > executablePositionsLimit;
        
        if(executableCount > executablePositionsLimit) {
            executableCount = executablePositionsLimit;
            _handleLeftoverPositions(poolId, executableTicks, executableCount, zeroForOne);
        }
        
        // Execute positions up to the limit
        for(uint256 i = 0; i < executableCount; i++) {
            int24 tick = executableTicks[i];
            
            // Get position key from appropriate mapping based on swap direction
            bytes32 posKey = zeroForOne ? 
                token1PositionAtTick[poolId][tick] : 
                token0PositionAtTick[poolId][tick];
            
            // Skip if no position exists at this tick
            if(posKey == bytes32(0)) continue;
            
            // Execute the position
            _executePosition(key, poolId, posKey, tick);
        }
    }

    /**
     * @notice Execute a single limit order position
     * @dev Processes a single position identified by its position key
     * @param key The pool key
     * @param poolId The pool identifier
     * @param posKey The position key to execute
     * @param tick The tick with the executable position
     */
    function _executePosition(
        PoolKey memory key,
        PoolId poolId,
        bytes32 posKey,
        int24 tick
    ) internal returns (BalanceDelta callerDelta, BalanceDelta feeDelta) {
        // Decode position data
        (int24 bottomTick, int24 topTick, bool isToken0, ) = _decodePositionKey(posKey);
        
        // Burn position liquidity and collect fees
        (callerDelta, feeDelta) = callbackState._burnLimitOrder(
            key,
            bottomTick,
            topTick,
            positionState[poolId][posKey].totalLiquidity
        );
        
        // Update position state
        _retrackPositionFee(poolId, posKey, feeDelta);
        positionState[poolId][posKey].isActive = false;
        
        // Clear keeper flag if set
        if(positionState[poolId][posKey].isWaitingKeeper) {
            positionState[poolId][posKey].isWaitingKeeper = false;
        }
            
        // Remove position from tick tracking
        PositionManagement.removePositionFromTick(
            isToken0 ? token0PositionAtTick : token1PositionAtTick,
            isToken0 ? token0TickBitmap : token1TickBitmap,
            key,
            tick
        );
        
        // Update nonce for this position type to prevent key reuse
        bytes32 baseKey = bytes32(
            uint256(uint24(bottomTick)) << 232 |
            uint256(uint24(topTick)) << 208 |
            uint256(isToken0 ? 1 : 0)
        );
        currentNonce[poolId][baseKey]++;
        
        // Emit event for executed order
        emit OrderExecuted(poolId, posKey);
    }

    /**
     * @notice Handle positions that exceed the execution limit
     * @dev Marks positions for keeper execution and emits event with position details
     * @param poolId The pool identifier
     * @param executableTicks Array of ticks with positions
     * @param executableCount Number of positions being executed in this transaction
     * @param zeroForOne Direction of the swap
     */
    function _handleLeftoverPositions(
        PoolId poolId,
        int24[] memory executableTicks,
        uint256 executableCount,
        bool zeroForOne
    ) internal {
        uint256 leftoverCount = executableTicks.length - executableCount;
        
        // Mark remaining positions for keeper execution
        for(uint256 i = executableCount; i < executableTicks.length; i++) {
            int24 tick = executableTicks[i];
            bytes32 posKey = zeroForOne ? 
                token1PositionAtTick[poolId][tick] : 
                token0PositionAtTick[poolId][tick];
                
            positionState[poolId][posKey].isWaitingKeeper = true;
        }
        
        // Prepare event data for remaining positions
        PositionTickRange[] memory leftOvers = new PositionTickRange[](leftoverCount);
        
        for(uint256 i = 0; i < leftoverCount; i++) {
            uint256 tickIndex = i + executableCount;
            int24 tick = executableTicks[tickIndex];
            bytes32 posKey = zeroForOne ? 
                token1PositionAtTick[poolId][tick] : 
                token0PositionAtTick[poolId][tick];
                
            (int24 bottomTick, int24 topTick, bool isToken0, ) = _decodePositionKey(posKey);
            leftOvers[i] = PositionTickRange({
                bottomTick: bottomTick,
                topTick: topTick,
                isToken0: isToken0
            });
        }
        
        // Emit event with positions that need keeper execution
        emit PositionsLeftOver(poolId, leftOvers);
    }

    /// @notice Finds ticks with executable limit orders based on price movement
    /// @dev Uses TickBitmap library for efficient tick scanning
    /// @param poolId The pool identifier
    /// @param tickBeforeSwap The tick before the swap started
    /// @param tickAfterSwap The tick after the swap completed
    /// @param zeroForOne Direction of the swap (true for 0→1, false for 1→0)
    /// @param tickSpacing The pool's tick spacing
    /// @return executableTicks Array of ticks with executable orders
    function _findOverlappingPositions(
        PoolId poolId,
        int24 tickBeforeSwap,
        int24 tickAfterSwap,
        bool zeroForOne,
        int24 tickSpacing
    ) internal view returns (int24[] memory) {
        // console.log("Search params - before:");
        // console.log(tickBeforeSwap);
        // console.log("Search params - after:");
        // console.log(tickAfterSwap);
        // console.log("Search params - zeroForOne:");
        // console.log(zeroForOne);

        // Calculate max possible ticks with orders
        uint256 absDiff = uint256(int256(abs(tickBeforeSwap - tickAfterSwap)));
        int24[] memory executableTicks = new int24[]((absDiff / uint256(int256(tickSpacing))) + 1);
        uint256 resultCount = 0;
        
        // Prepare bitmap access
        mapping(int16 => uint256) storage bitmap = zeroForOne ? 
            token1TickBitmap[poolId] : token0TickBitmap[poolId];
        
        // Store reference to position map
        mapping(int24 => bytes32) storage positionMap = zeroForOne ?
            token1PositionAtTick[poolId] : token0PositionAtTick[poolId];
        
        // Initialize tick to current price
        int24 tick = tickBeforeSwap;
        
        // Main loop - similar to Uniswap's approach
        while (true) {
            // Check if we've reached the end of our search range
            if (zeroForOne ? tick <= tickAfterSwap : tick >= tickAfterSwap) {
                break;
            }
            
            // Find next initialized tick (just like in Pool.sol)
            // int24 nextInitializedTick;
            // bool initialized;
            (int24 nextInitializedTick, bool initialized) = TickBitmap.nextInitializedTickWithinOneWord(
                bitmap,
                tick,
                tickSpacing,
                zeroForOne
            );
            
            // console.log("Checking tick:", tick);
            // console.log("Result - next tick:", nextInitializedTick);
            // console.log("Result - initialized:", initialized);
            
            // If we've gone beyond the search boundary, stop
            bool beyondBoundary = zeroForOne ? 
                nextInitializedTick <= tickAfterSwap : 
                nextInitializedTick > tickAfterSwap;
                
            // If we've gone beyond, adjust to the boundary
            if (beyondBoundary) {
                // Cap at the boundary
                nextInitializedTick = tickAfterSwap;
                initialized = false; // We don't know if the boundary is initialized
            }
            
            // Process the initialized tick if found
            if (initialized) {
                // bytes32 posKey = positionMap[nextInitializedTick];
                if (positionMap[nextInitializedTick] != bytes32(0)) {
                    executableTicks[resultCount++] = nextInitializedTick;
                }

            }
            
            // If we're at the end tick, we're done
            if (nextInitializedTick == tickAfterSwap) {
                break;
            }
            
            // Move to position just beyond this tick (exactly like Uniswap does)
            tick = zeroForOne ? 
                nextInitializedTick - 1 : // When going down, we need to go to the position before
                nextInitializedTick + 1;  // When going up, we need to go to the position after
        }
        
        // Resize array to match actual result count
        assembly {
            mstore(executableTicks, resultCount)
        }
        
        return executableTicks;
    }

    // Helper function to get absolute value
    function abs(int24 x) private pure returns (int24) {
        return x < 0 ? -x : x;
    }

// Position Management Functions

    /// @notice Updates or creates a user's position with new liquidity
    /// @dev Handles both new position creation and liquidity additions to existing positions
    /// @param poolId The unique identifier for the Uniswap V4 pool
    /// @param positionKey The unique identifier for the position
    /// @param liquidity The amount of liquidity to add
    /// @param user The address of the position owner
    function _updateUserPosition(PoolId poolId, bytes32 positionKey, uint128 liquidity, address user) internal {
        PositionState storage posState = positionState[poolId][positionKey];
        UserPosition storage position = userPositions[poolId][positionKey][user];

        if(!positionContributors[poolId][positionKey].contains(user)) {
            position.claimablePrincipal = ZERO_DELTA;
            position.fees = ZERO_DELTA;
            positionContributors[poolId][positionKey].add(user);
            userPositionKeys[user][poolId].add(positionKey);
        } else {
            if (position.liquidity != 0) {
                BalanceDelta feeDelta = posState.feePerLiquidity - position.lastFeePerLiquidity;
                int128 liq = int128(position.liquidity);
                BalanceDelta pendingFees = PositionManagement.calculateScaledUserFee(feeDelta, uint128(liq));
                if (pendingFees != ZERO_DELTA)
                    position.fees = position.fees + pendingFees;
            }
            
        }
        position.lastFeePerLiquidity = posState.feePerLiquidity;
        position.liquidity += liquidity;
        posState.totalLiquidity += liquidity;
    }


    /// @notice Callback function for handling pool manager unlock operations
    /// @dev Called by the pool manager during operations that modify pool state
    /// @param data Encoded callback data containing operation type and parameters
    /// @return bytes Encoded response data based on the callback type
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager));
        UnlockCallbackData memory cbd = abi.decode(data, (UnlockCallbackData));
        CallbackType ct = cbd.callbackType;
        
        if(ct == CallbackType.CREATE_ORDERS) return callbackState.handleCreateOrdersCallback(abi.decode(cbd.data, (CreateOrdersCallbackData)));
        if(ct == CallbackType.CLAIM_ORDER) return callbackState.handleClaimOrderCallback(abi.decode(cbd.data, (ClaimOrderCallbackData)));
        if(ct == CallbackType.CANCEL_ORDER) return callbackState.handleCancelOrderCallback(abi.decode(cbd.data, (CancelOrderCallbackData)));
        return _handleKeeperExecuteCallback(cbd.data);
    }

    /// @notice Handles the execution of keeper-managed limit orders
    /// @dev Called during unlockCallback for KEEPER_EXECUTE_ORDERS operations
    ///      1. Validates positions are still waiting for keeper execution
    ///      2. Burns liquidity and processes fees for each position
    ///      3. Updates position state and nonces
    ///      4. Removes executed positions from tracking
    /// @param data Encoded KeeperExecuteCallbackData containing positions to execute
    /// @return bytes Encoded arrays of caller deltas and fee deltas from executions
    function _handleKeeperExecuteCallback(bytes memory data) internal returns (bytes memory) {
        KeeperExecuteCallbackData memory keeperData = abi.decode(data, (KeeperExecuteCallbackData));
        PoolId poolId = keeperData.key.toId();
        
        uint256 len = keeperData.positions.length;
        BalanceDelta[] memory callerDeltas = new BalanceDelta[](len);
        BalanceDelta[] memory feeDeltas = new BalanceDelta[](len);
        
        for(uint256 i = 0; i < len; i++) {
            PositionTickRange memory position = keeperData.positions[i];
            int24 executableTick = position.isToken0 ? position.topTick : position.bottomTick;
            
            // Get the position key from the tick
            bytes32 positionKey = position.isToken0 ? 
                token0PositionAtTick[poolId][executableTick] : 
                token1PositionAtTick[poolId][executableTick];
            
            if (!positionState[poolId][positionKey].isWaitingKeeper) continue;
            
            // Execute the position using the shared function
            (callerDeltas[i], feeDeltas[i]) = _executePosition(keeperData.key, poolId, positionKey, executableTick);
        }
        
        return abi.encode(callerDeltas, feeDeltas);
    }


    /// @notice Updates the accumulated fees per liquidity for a position
    /// @dev Calculates and updates the fee accumulator for both tokens based on the provided fee delta
    ///      The calculation scales fees by 1e18 to maintain precision when dividing by total liquidity
    ///      Fees per liquidity are tracked separately for token0 and token1
    /// @param poolId The unique identifier of the pool containing the position
    /// @param positionKey The unique identifier of the position being updated
    /// @param feeDelta The change in fees to be distributed, containing both token0 and token1 amounts
    function _retrackPositionFee(
        PoolId poolId,
        bytes32 positionKey,
        BalanceDelta feeDelta
    ) internal {
        PositionState storage posState = positionState[poolId][positionKey];
        if (posState.totalLiquidity == 0) return;

        if(feeDelta == ZERO_DELTA) return;
        
        posState.feePerLiquidity = posState.feePerLiquidity + 
            PositionManagement.calculateScaledFeePerLiquidity(feeDelta, posState.totalLiquidity);
    }

    function _handleTokenTransfer(
        bool isToken0,
        uint256 amount,
        PoolKey memory key
    ) internal nonReentrant {
        if (isToken0) {
            // If isToken0 is true and native token is always currency0, check for ETH
            if (key.currency0.isAddressZero()) {
                // Check if sufficient ETH was sent
                require(msg.value >= amount);
                
                // Handle any excess ETH (return it to the sender)
                if (msg.value > amount) {
                    (bool success, ) = msg.sender.call{value: msg.value - amount}("");
                    require(success);
                }
            } else {
                // Prevent sending ETH with non-native token0 orders
                require(msg.value == 0);
                // Non-native token0
                IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(msg.sender, address(this), amount);
            }
        } else {
            // Prevent sending ETH with non-native token0 orders
            require(msg.value == 0);
            // If isToken0 is false, we're dealing with currency1 which is never native
            IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

// =========== Getter Functions ===========

    function getUserPositions(
        address user,
        PoolId poolId
    ) external view override returns (PositionInfo[] memory positions) {
        EnumerableSet.Bytes32Set storage userKeys = userPositionKeys[user][poolId];
        uint256 length = userKeys.length();
        positions = new PositionInfo[](length);
        
        for(uint i = 0; i < length; i++) {
            bytes32 key = userKeys.at(i);
            UserPosition memory position = userPositions[poolId][key][user];
            // (int24 bottomTick, int24 topTick, bool isToken0, ) = _decodePositionKey(key);
            
            positions[i] = PositionInfo({
                liquidity: position.liquidity,
                fees: position.fees,
                positionKey: key
            });
        }
    }

    // function _constructPositionParams(
    //     bytes32 positionKey,
    //     address user,
    //     PoolId poolId
    // ) internal view returns (PositionManagement.PositionParams memory) {
    //     (int24 bottomTick, int24 topTick, bool isToken0, ) = _decodePositionKey(positionKey);
        
    //     return PositionManagement.PositionParams({
    //         position: userPositions[poolId][positionKey][user],
    //         posState: positionState[poolId][positionKey],
    //         poolManager: poolManager,
    //         poolId: poolId,
    //         bottomTick: bottomTick,
    //         topTick: topTick,
    //         isToken0: isToken0,
    //         feeDenom: FEE_DENOMINATOR,
    //         hookFeePercentage: hook_fee_percentage
    //     });
    // }

    // /// @notice Get the balances for a specific position of a user
    // /// @param user The address of the user
    // /// @param poolId The pool identifier
    // /// @param positionKey The specific position key to query
    // /// @return posBalances The balance details for the specific position
    // function getUserPositionBalances(
    //     address user,
    //     PoolId poolId,
    //     bytes32 positionKey
    // ) external view returns (
    //     PositionBalances memory posBalances
    // ) {

        
    //     // Get the balance for the specific position only
    //     posBalances = PositionManagement.getPositionBalances(
    //         _constructPositionParams(positionKey, user, poolId)
    //     );
    // }

// =========== Admin Functions ===========

    function setHook(address _hook) external onlyOwner {
        hook = _hook;
    }

    function setWhitelistedPool(PoolId poolId, bool isWhitelisted) external onlyOwner {
        whitelistedPool[poolId] = isWhitelisted;
    }
    
    function setKeeper(address _keeper, bool _isKeeper) external onlyOwner {
        isKeeper[_keeper] = _isKeeper;
    }
    
    /// @notice Sets the maximum number of positions that can be executed in a single transaction
    /// @dev This limit prevents excessive gas consumption during batch executions
    ///      Positions beyond this limit will be marked for keeper execution
    /// @param _limit The new maximum number of positions that can be executed at once
    function setExecutablePositionsLimit(uint256 _limit) external override onlyOwner {
        require(_limit > 0);
        executablePositionsLimit = _limit;
    }


    /// @notice Sets the minimum order amount for a specific currency
    /// @dev Used to prevent dust orders that could cost more in gas than they're worth
    /// @param currency The token address for which to set the minimum amount
    /// @param _minAmount The minimum amount of tokens required to create an order for this currency
    function setMinAmount(Currency currency, uint256 _minAmount) external override onlyOwner {
        minAmount[currency] = _minAmount;
    }

    /// @notice Sets the hook fee percentage
    /// @param _percentage New fee percentage (scaled by FEE_DENOMINATOR)
    function setHookFeePercentage(uint256 _percentage) external onlyOwner {
        require(_percentage < FEE_DENOMINATOR);
        hook_fee_percentage = _percentage;
        callbackState.hookFeePercentage = _percentage;  
    }

    /// @notice Sets the maximum number of orders that can be created at once
    /// @dev Prevents excessive memory usage and gas costs from too many active orders
    /// @param _limit The new maximum number of orders allowed per pool
    function setMaxOrderLimit(uint24 _limit) external onlyOwner {
        require(_limit > 1);
        maxOrderLimit = _limit;
    }


    /// @notice Pauses contract functionality
    /// @dev Only callable by the contract owner
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses contract functionality
    /// @dev Only callable by the contract owner
    function unpause() external onlyOwner {
        _unpause();
    }


    /// @notice Executes positions that were previously marked for keeper execution due to position limit overflow
    /// @dev This function performs a two-step process:
    ///      1. Validates and filters positions that are ready for execution based on current price
    ///      2. Executes valid positions through the pool manager
    /// @param key The Uniswap V4 pool identifier containing the positions
    /// @param waitingPositions Array of positions previously marked for keeper execution
    function executeOrderByKeeper(
        PoolKey calldata key,
        PositionTickRange[] memory waitingPositions
    ) external {
        require(isKeeper[msg.sender]);
        if (waitingPositions.length == 0) return;
        PoolId poolId = key.toId();
        (, int24 currentTick, ,) = StateLibrary.getSlot0(poolManager, poolId);
        
        // Identify executable positions
        uint256 executableCount = 0;

        for (uint256 i = 0; i < waitingPositions.length; i++) {
            PositionTickRange memory position = waitingPositions[i];
            
            // Calculate position key directly instead of reading from storage
            (, bytes32 positionKey) = PositionManagement.getPositionKeys(currentNonce, poolId, position.bottomTick, position.topTick, position.isToken0);
            
            // Validate position
            bool isExecutable = position.isToken0 ? 
                currentTick >= position.topTick :
                currentTick < position.bottomTick;
            
            if (positionState[poolId][positionKey].isWaitingKeeper && isExecutable && positionState[poolId][positionKey].totalLiquidity > 0) {
                // Keep this position for execution
                waitingPositions[executableCount++] = position;
            } else {
                // No longer needs keeper execution
                positionState[poolId][positionKey].isWaitingKeeper = false;
            }
        }
        
        // Resize array
        assembly {
            mstore(waitingPositions, executableCount)
        }
        
        // Execute the positions
        if (executableCount > 0) {
            poolManager.unlock(
                abi.encode(
                    UnlockCallbackData({
                        callbackType: CallbackType.KEEPER_EXECUTE_ORDERS,
                        data: abi.encode(
                            KeeperExecuteCallbackData({
                                key: key,
                                positions: waitingPositions
                            })
                        )
                    })
                )
            );
        }
    }
}