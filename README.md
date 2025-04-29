# LimitOrderHook System

A comprehensive limit order system for Uniswap v4 pools, enabling limit orders and scale orders with keeper functionality and fee management.

## Overview

The LimitOrderHook system consists of three main components:
- LimitOrderHook: Core hook contract handling swap events
- LimitOrderManager: Advanced order management and execution logic
- Supporting Libraries: Specialized functionality for position management, callbacks, and tick calculations

## Scope

This project includes the following contracts that are in scope:

- `src/LimitOrderManager.sol` - Core order management contract
- `src/LimitOrderHook.sol` - Hook contract for Uniswap v4 integration
- `src/CallbackHandler.sol` - Callback handling library
- `src/CurrencySettler.sol` - Currency settlement library
- `src/PositionManagement.sol` - Position calculation and management library
- `src/TickLibrary.sol` - Tick math and validation library
- `src/ILimitOrderManager.sol` - Interface definitions

**Note:** `src/LimitOrderLens.sol` is **NOT** in scope.

## Key Features

### Order Types
- Single-tick limit orders
- Scale orders (multiple single-tick limit orders across a price range)

### Order Management
- Batch order creation and cancellation
- Position tracking and fee accounting
- Keeper system for handling excess orders
- Treasury fee collection
- Minimum order amount enforcement

### Fee Distribution
- Per-position fee tracking
- Multi-user fee sharing for shared positions
- Hook fee percentage (configurable by owner)
- Automated fee settlement during claims

## Architecture

### LimitOrderHook
Primary hook contract interfacing with Uniswap v4 pools.

```solidity
contract LimitOrderHook is BaseHook {
    LimitOrderManager public immutable limitOrderManager;
    
    // Hooks implemented:
    - beforeSwap: Records tick before swap
    - afterSwap: Triggers order execution
}
```

### LimitOrderManager
Core order management contract handling:
- Order creation and cancellation
- Position tracking
- Fee management
- Keeper operations

```solidity
contract LimitOrderManager {
    // Key state variables
    mapping(PoolId => mapping(bytes32 => PositionState)) public positionState;
    mapping(PoolId => mapping(int16 => uint256)) public token0TickBitmap;
    mapping(PoolId => mapping(int16 => uint256)) public token1TickBitmap;
    mapping(PoolId => mapping(int24 => bytes32)) public token0PositionAtTick;
    mapping(PoolId => mapping(int24 => bytes32)) public token1PositionAtTick;
    mapping(address => mapping(PoolId => EnumerableSet.Bytes32Set)) private userPositionKeys;
    
    // Core functionality
    function createLimitOrder(...) external returns (CreateOrderResult memory)
    function createScaleOrders(...) external returns (CreateOrderResult[] memory)
    function executeOrder(...) external
    function cancelOrder(...) external
    function claimOrder(...) external
}
```

## Key Concepts

### Position Structure
```solidity
struct PositionState {
    BalanceDelta feePerLiquidity;  // Accumulated fees per unit of liquidity
    uint128 totalLiquidity;        // Total liquidity in position
    bool isActive;                 // Position status
    bool isWaitingKeeper;         // Keeper execution flag
    uint256 currentNonce;         // Current nonce to prevent position key reuse
}
```

### Order Creation Process
1. Validate input parameters and amounts
2. Calculate tick ranges based on order type
3. Handle token transfers
4. Create liquidity position
5. Update position tracking
6. Emit relevant events

### Execution Flow
1. Swap triggers hook callback
2. Find overlapping positions
3. Execute positions within limit
4. Mark excess positions for keeper
5. Update position states
6. Distribute fees

### Fee Management
- Fees tracked per position using feePerLiquidity accumulator
- Hook fees sent to treasury during claims
- User fees distributed proportionally to liquidity contribution

## Usage Examples

### Creating a Single Limit Order
```solidity
CreateOrderResult memory result = limitOrderManager.createLimitOrder(
    true,           // isToken0
    targetTick,     // price tick
    1 ether,        // amount
    poolKey         // pool identification
);
```

### Creating Scale Orders
```solidity
CreateOrderResult[] memory results = limitOrderManager.createScaleOrders(
    true,           // isToken0
    bottomTick,     // range start
    topTick,        // range end
    10 ether,       // total amount
    5,              // number of orders
    1.5e18,         // size skew
    poolKey
);
```

### Keeper Operations
```solidity
// Execute leftover positions
limitOrderManager.executeOrderByKeeper(
    poolKey,
    waitingPositions  // positions marked for keeper execution
);
```

## Security Considerations

### Access Control
- Owner-only functions for configuration
- Keeper validation for specialized operations
- Position-based access control for user operations

### Safety Checks
- Minimum amount validation
- Tick range validation
- Position state verification
- Duplicate execution prevention

### Fee Protection
- Safe fee calculation and distribution
- Protected treasury fee collection
- Multi-user fee tracking

## Gas Optimization Features

- Batch operations for order management
- Efficient position tracking using EnumerableSet
- Optimized fee calculations
- Smart keeper system to handle high load

## Configuration Options

### Owner Controls
- Set executable positions limit
- Configure minimum order amounts
- Manage keeper addresses
- Adjust hook fee percentage

### System Limits
- Maximum orders per pool
- Executable positions per transaction
- Minimum order amounts per token

## Trusted Roles

The system operates with several privileged roles that have special permissions:

### LimitOrderManager Roles

#### Owner
- Set the hook address
- Whitelist/delist pools
- Configure keeper addresses
- Set executable positions limit
- Set minimum order amounts
- Set hook fee percentage
- Pause/unpause contract functionality
- Set maximum order limit

#### Keepers
- Execute positions marked for keeper execution
- Execute emergency cancellation of orders on behalf of users

### LimitOrderHook Roles

#### Admin (DEFAULT_ADMIN_ROLE)
- Manage other roles
- Overall administrative control

#### Fee Manager (FEE_MANAGER_ROLE)
- Update dynamic LP fee rates for pools

These trusted roles are assigned to secure multisigs and/or OZ Defender (for keepers) to ensure decentralized control and prevent centralization risks.

## Events

```solidity
event LimitOrderExecuted(PoolId indexed poolId, address indexed owner, uint256 amount0, uint256 amount1);
event LimitOrderClaimed(PoolId indexed poolId, address owner, int24 bottomTick, int24 topTick);
event OrderCreated(address user, PoolId indexed poolId, bytes32 positionKey);
event OrderCanceled(address orderOwner, PoolId indexed poolId, bytes32 positionKey);
event OrderExecuted(PoolId indexed poolId, bytes32 positionKey);
event PositionsLeftOver(PoolId indexed poolId, PositionTickRange[] leftoverPositions);
```

## Development and Testing

The system includes comprehensive test suites covering:
- Basic order operations
- Scale order functionality
- Keeper system
- Fee distribution
- Gas optimization
- Edge cases and security scenarios

## Dependencies

- Uniswap v4 core contracts
- OpenZeppelin contracts
- Safe math libraries
- Custom position management libraries

## Build Instructions

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (for Solidity development)
- Git

### Setup Instructions
1. Clone the repository
```bash
git clone https://github.com/your-username/gamma-univ4-limit-orders.git
cd gamma-univ4-limit-orders
```

2. Install and update submodules
```bash
# Initialize and update all submodules recursively
git submodule update --init --recursive
```

3. Build the project
```bash
forge build
```

4. Run tests
```bash
forge test
```

### Troubleshooting Submodules
If you encounter issues with submodules, try the following:

```bash
# Force update of v4-periphery
cd lib/v4-periphery
git checkout main
git pull
git submodule update --init --recursive
cd ../..

# Verify all submodules are properly initialized
ls -la lib/v4-periphery/lib
```

### Development Workflow
1. All files EXCEPT FOR LimitOrderLens.sol in `src/` directory are in scope
2. Run tests to verify your changes: `forge test`
3. For gas optimization analysis: `forge test --gas-report`
# gamma-univ4-limit-orders
