// SPDX-License-Identifier: BSL
pragma solidity ^0.8.24;

import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

interface ILimitOrderManager {
    // =========== Structs ===========
    struct PositionTickRange {
        int24 bottomTick;
        int24 topTick;
        bool isToken0;
    }

    struct ClaimableTokens {
        Currency token;  
        uint256 principal;
        uint256 fees;
    }

    struct UserPosition {
        uint128 liquidity;                
        BalanceDelta lastFeePerLiquidity; 
        BalanceDelta claimablePrincipal;  
        BalanceDelta fees;                
    }

    struct PositionState {
        BalanceDelta feePerLiquidity;  
        uint128 totalLiquidity;        
        bool isActive;
        bool isWaitingKeeper;
        uint256 currentNonce;
    }

    struct PositionInfo {
        uint128 liquidity;
        BalanceDelta fees;
        bytes32 positionKey;
    }

    struct PositionBalances {
        uint256 principal0;
        uint256 principal1;
        uint256 fees0;
        uint256 fees1;
    }

    struct CreateOrderResult {
        uint256 usedAmount;
        bool isToken0;
        int24 bottomTick;
        int24 topTick;
    }

    struct ScaleOrderParams {
        bool isToken0;
        int24 bottomTick;
        int24 topTick;
        uint256 totalAmount;
        uint256 totalOrders;
        uint256 sizeSkew;
    }
    struct OrderInfo {
        int24 bottomTick;
        int24 topTick;
        uint256 amount;
        uint128 liquidity;
    }

    struct CreateOrdersCallbackData {
        PoolKey key;
        OrderInfo[] orders;
        bool isToken0;
        address orderCreator;
    }

    struct CancelOrderCallbackData {
        PoolKey key;
        int24 bottomTick;
        int24 topTick;
        uint128 liquidity;
        address user;
    }

    struct ClaimOrderCallbackData {
        BalanceDelta principal;
        BalanceDelta fees;
        PoolKey key;
        address user;
    }

    struct KeeperExecuteCallbackData {
        PoolKey key;
        PositionTickRange[] positions;
    }

    // struct BatchOrderCallbackData {
    //     PoolKey key;
    //     ScaleOrderInfo[] orders;
    //     bool isToken0;
    //     uint256 totalAmount;
    // }

    struct UnlockCallbackData {
        CallbackType callbackType;
        bytes data;
    }

    enum CallbackType {
        CREATE_ORDERS,
        // CREATE_ORDER,
        CLAIM_ORDER,
        CANCEL_ORDER,
        // CREATE_SCALE_ORDERS,
        KEEPER_EXECUTE_ORDERS
    }

    // =========== Errors ===========
    // error InvalidPrice(uint256 price);
    // error TickNotDivisibleBySpacing(int24 tick, int24 spacing);
    // error InvalidExecutionDirection(bool isToken0, int24 targetTick, int24 currentTick);
    // error TickOutOfBounds(int24 tick);
    // error PriceMustBeGreaterThanZero();
    error FeePercentageTooHigh();
    error AmountTooLow();
    error AddressZero();
    error NotAuthorized();
    error PositionIsWaitingForKeeper();
    error ZeroLimit();
    error NotWhitelistedPool();
    // error RoundedTicksTooClose(int24 currentTick, int24 roundedCurrentTick, int24 targetTick, int24 roundedTargetTick, bool isToken0);    
    // error WrongTargetTick(int24 currentTick, int24 targetTick, bool isToken0);
    // error WrongTickRange(int24 bottomTick, int24 topTick, int24 currentTick, int24 targetTick, bool isToken0, bool isRange);
    // error RoundedTargetTickLessThanRoundedCurrentTick(int24 currentTick, int24 roundedCurrentTick, int24 targetTick, int24 roundedTargetTick);
    // error RoundedTargetTickGreaterThanRoundedCurrentTick(int24 currentTick, int24 roundedCurrentTick, int24 targetTick, int24 roundedTargetTick);
    // error InvalidScaleParameters();
    // error InvalidSizeSkew();
    error MinimumAmountNotMet(uint256 provided, uint256 minimum);
    error MaxOrdersExceeded();
    error UnknownCallbackType();
    // error InvalidTickRange();
    // error MinimumTwoOrders();
    // =========== Events ===========
    event LimitOrderExecuted(PoolId indexed poolId, address indexed owner, uint256 amount0, uint256 amount1);
    event LimitOrderClaimed(PoolId indexed poolId, address owner, int24 bottomTick, int24 topTick);
    event OrderCreated(address user, PoolId indexed poolId, bytes32 positionKey);
    event OrderCanceled(address orderOwner, PoolId indexed poolId, bytes32 positionKey);
    event OrderExecuted(PoolId indexed poolId, bytes32 positionKey);
    event PositionsLeftOver(PoolId indexed poolId, PositionTickRange[] leftoverPositions);
    event KeeperWaitingStatusReset(bytes32 positionKey, int24 bottomTick, int24 topTick, int24 currentTick);
    event HookFeePercentageUpdated (uint256 percentage);
    // event EmergencyCancelExecuted(address indexed user, PoolId indexed poolId, uint256 canceledCount);
    // event RangeOrdersStatusUpdated(bool allowRangeOrders);

    // =========== Functions ===========
    function createLimitOrder(
        // LimitOrderParams calldata params,
        bool isToken0,
        int24 targetTick,
        uint256 amount,
        PoolKey calldata key
    ) external payable returns (CreateOrderResult memory);

    // /// @notice Creates a range order with directly specified lower and upper tick bounds
    // /// @param isToken0 True if order is for token0, false for token1
    // /// @param bottomTick The exact lower tick bound for the range order
    // /// @param topTick The exact upper tick bound for the range order
    // /// @param amount The amount of tokens to use for the order
    // /// @param key The pool key identifying the specific pool
    // /// @return result The created order details
    // function createRangeOrder(
    //     bool isToken0,
    //     int24 bottomTick,
    //     int24 topTick,
    //     uint256 amount,
    //     PoolKey calldata key
    // ) external payable returns (CreateOrderResult memory);

    function createScaleOrders(
        // ScaleOrderParams calldata params,
        bool isToken0,
        int24 bottomTick,
        int24 topTick,
        uint256 totalAmount,
        uint256 totalOrders,
        uint256 sizeSkew,
        PoolKey calldata key
    ) external payable returns (CreateOrderResult[] memory results);

    function setHook(address _hook) external;
    
    function executeOrder(
        PoolKey calldata key,
        int24 tickBeforeSwap,
        int24 tickAfterSwap,
        bool zeroForOne
    ) external;

    function cancelOrder(PoolKey calldata key, bytes32 positionKey) external;

    function positionState(PoolId poolId, bytes32 positionKey) 
        external 
        view 
        returns (
            BalanceDelta feePerLiquidity,
            uint128 totalLiquidity,
            bool isActive,
            bool isWaitingKeeper,
            uint256 currentNonce
        );

    function cancelBatchOrders(
        PoolKey calldata key,
        uint256 offset,             
        uint256 limit
    ) external returns (uint256 canceledCount);

    function claimOrder(PoolKey calldata key, bytes32 positionKey, address user) external;

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
    ) external returns (uint256 claimedCount);

    function executeOrderByKeeper(PoolKey calldata key, PositionTickRange[] memory waitingPositions) external;

    // function setKeepers(address[] calldata _keepers) external;
    // function removeKeepers(address[] calldata _keepers) external;
    function setExecutablePositionsLimit(uint256 _limit) external;
    function setMinAmount(Currency currency, uint256 _minAmount) external;

    // View functions
    // function getUserPositionCount(address user, PoolId poolId) external view returns (uint256);

    // function getUserPositionKeys(
    //     address user,
    //     PoolId poolId,
    //     uint256 offset,
    //     uint256 limit
    // ) external view returns (bytes32[] memory keys);

    function getUserPositions(address user, PoolId poolId) external view returns (PositionInfo[] memory positions);

    // function getUserPositionBalances(address user, PoolId poolId, bytes32 positionKey) external view returns (PositionBalances memory posBalances);   

    function setKeeper(address _keeper, bool _isKeeper) external;
    // function flipKeepers(address[] calldata _keepers) external;

    // function decodePositionKey(bytes32 key) external pure returns (
    //     int24 bottomTick,
    //     int24 topTick,
    //     bool isToken0,
    //     uint256 nonce
    // );

    // Additional view functions for state variables
    function currentNonce(PoolId poolId, bytes32 baseKey) external view returns (uint256);
    function treasury() external view returns (address);
    function executablePositionsLimit() external view returns (uint256);
    function isKeeper(address) external view returns (bool);
    function minAmount(Currency currency) external view returns (uint256);

    // Add new view functions to help unit testing
    // function getPositionList(PoolId _poolId, bool _isToken0) external view returns (PositionTickRange[] memory);
    // function getPositionContributorsLength(PoolId _poolId, bytes32 _positionKey) external view returns(uint256 contributorsAmount);
    // function getPositionContributor(PoolId _poolId, bytes32 _positionKey, uint256 _idx) external view returns(address contributor);

    // // State variables
    // function allowRangeOrders() external view returns (bool);
    
    // /// @notice Enables or disables the ability to create range orders
    // /// @param _allowRangeOrders True to allow range orders, false to disable them
    // function setAllowRangeOrders(bool _allowRangeOrders) external;
}