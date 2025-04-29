// SPDX-License-Identifier: BSL
pragma solidity ^0.8.24;

import {LimitOrderManager} from "./LimitOrderManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILimitOrderManager} from "./ILimitOrderManager.sol";

interface ERC20MinimalInterface {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}


/// @title LimitOrderLens
/// @notice Helper contract to provide view functions for accessing data from LimitOrderManager
/// @dev This contract is designed to aid frontend development by providing easy access to user information
contract LimitOrderLens is Ownable {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Reference to the LimitOrderManager contract
    LimitOrderManager public immutable limitOrderManager;
    
    // Direct reference to the pool manager
    IPoolManager public immutable poolManager;

    // Mapping from PoolId to PoolKey
    mapping(PoolId => PoolKey) public poolIdToKey;
    
    // Set of pool IDs for iteration (stored as bytes32)
    EnumerableSet.Bytes32Set private poolIdBytes;

    // Constants
    BalanceDelta public constant ZERO_DELTA = BalanceDelta.wrap(0);

    constructor(address _limitOrderManagerAddr, address _owner) Ownable(_owner) {
        require(_limitOrderManagerAddr != address(0), "Invalid LimitOrderManager address");
        limitOrderManager = LimitOrderManager(_limitOrderManagerAddr);
        
        // Get poolManager directly from LimitOrderManager
        poolManager = IPoolManager(limitOrderManager.poolManager());
    }

    /// @notice Get the PoolKey for a given PoolId
    /// @param poolId The pool identifier
    /// @return key The corresponding PoolKey
    function getPoolKey(PoolId poolId) external view returns (PoolKey memory key) {
        key = poolIdToKey[poolId];
        // Use bytes32 values for comparison
        require(PoolId.unwrap(poolId) != bytes32(0) && key.fee != 0, "Pool key not found");
        return key;
    }

    /// @notice Add a PoolId and its corresponding PoolKey to the mapping
    /// @param poolId The pool identifier
    /// @param key The corresponding PoolKey
    function addPoolId(PoolId poolId, PoolKey calldata key) external onlyOwner {
        // Compare the unwrapped bytes32 values
        require(PoolId.unwrap(key.toId()) == PoolId.unwrap(poolId), "PoolId does not match PoolKey");
        poolIdToKey[poolId] = key;
        poolIdBytes.add(PoolId.unwrap(poolId));
    }

    /// @notice Remove a PoolId from the mapping
    /// @param poolId The pool identifier to remove
    function removePoolId(PoolId poolId) external onlyOwner {
        delete poolIdToKey[poolId];
        poolIdBytes.remove(PoolId.unwrap(poolId));
    }

    /// @notice Decode a position key to extract its components
    /// @param positionKey The position key to decode
    /// @return bottomTick The bottom tick of the position
    /// @return topTick The top tick of the position
    /// @return isToken0 Whether the position is for token0
    /// @return nonce The nonce value used in the position
    function decodePositionKey(bytes32 positionKey) public pure returns (
        int24 bottomTick,
        int24 topTick,
        bool isToken0,
        uint256 nonce
    ) {
        uint256 value = uint256(positionKey);
        return (
            int24(uint24(value >> 232)),          // bottomTick
            int24(uint24(value >> 208)),          // topTick
            (value & 1) == 1,                     // isToken0
            (value >> 8) & ((1 << 200) - 1)       // nonce (200 bits)
        );
    }

    /// @notice Get positions for a specific user in a specific pool
    /// @param user The address of the user
    /// @param poolId The pool identifier
    /// @return positions Array of position information
    function getUserPositionsForPool(
        address user,
        PoolId poolId
    ) internal view returns (LimitOrderManager.PositionInfo[] memory positions) {
        // Use getUserPositions from LimitOrderManager, not getUserPositionBalances
        // For detailed balance info, use the getPositionBalances function in this contract
        return limitOrderManager.getUserPositions(user, poolId);
    }

    /// @notice Get the number of positions a user has in a specific pool
    /// @param user The address of the user
    /// @param poolId The pool identifier
    /// @return count The number of positions
    function getUserPositionCount(
        address user,
        PoolId poolId
    ) external view returns (uint256) {
        LimitOrderManager.PositionInfo[] memory positions = getUserPositionsForPool(user, poolId);
        return positions.length;
    }

    /// @notice Get all positions for a user across all tracked pools
    /// @param user The address of the user
    /// @return allPositions Array of user positions with pool information
    function getUserPositions(address user) internal view returns (
        UserPositionWithPool[] memory allPositions
    ) {
        // Calculate total positions count
        uint256 totalPositions = 0;
        uint256 poolCount = poolIdBytes.length();
        
        // First pass: count positions
        for (uint256 i = 0; i < poolCount; i++) {
            PoolId poolId = PoolId.wrap(poolIdBytes.at(i));
            LimitOrderManager.PositionInfo[] memory positions = getUserPositionsForPool(user, poolId);
            totalPositions += positions.length;
        }
        
        // Allocate result array
        allPositions = new UserPositionWithPool[](totalPositions);
        
        // Second pass: fill the array
        uint256 positionIndex = 0;
        for (uint256 i = 0; i < poolCount; i++) {
            PoolId poolId = PoolId.wrap(poolIdBytes.at(i));
            PoolKey memory poolKey = poolIdToKey[poolId];
            LimitOrderManager.PositionInfo[] memory positions = getUserPositionsForPool(user, poolId);
            
            for (uint256 j = 0; j < positions.length; j++) {
                (int24 bottomTick, int24 topTick, bool isToken0,) = decodePositionKey(positions[j].positionKey);
                
                allPositions[positionIndex] = UserPositionWithPool({
                    poolId: poolId,
                    poolKey: poolKey,
                    positionKey: positions[j].positionKey,
                    bottomTick: bottomTick,
                    topTick: topTick,
                    isToken0: isToken0,
                    liquidity: positions[j].liquidity,
                    fees: positions[j].fees
                });
                
                positionIndex++;
            }
        }
        
        return allPositions;
    }

    /// @notice Get count of pools being tracked
    /// @return count The number of pools
    function getPoolCount() external view returns (uint256) {
        return poolIdBytes.length();
    }

    /// @notice Get a pool ID at a specific index
    /// @param index The index to query
    /// @return poolId The pool ID at the given index
    function getPoolIdAt(uint256 index) external view returns (PoolId) {
        require(index < poolIdBytes.length(), "Index out of bounds");
        return PoolId.wrap(poolIdBytes.at(index));
    }

    /// @notice Get the PoolId for a given PoolKey
    /// @param key The pool key
    /// @return poolId The corresponding PoolId
    function getPoolId(PoolKey calldata key) external pure returns (PoolId) {
        return key.toId();
    }

    /// @notice Helper function to get user position data from LimitOrderManager
    /// @param poolId The pool identifier
    /// @param positionKey The position key
    /// @param user The user address
    /// @return liquidity The position liquidity
    /// @return lastFeePerLiquidity The last fee per liquidity checkpoint
    /// @return claimablePrincipal The claimable principal balance
    /// @return fees The accumulated fees
    function getUserPosition(
        PoolId poolId,
        bytes32 positionKey,
        address user
    ) internal view returns (
        uint128 liquidity,
        BalanceDelta lastFeePerLiquidity,
        BalanceDelta claimablePrincipal,
        BalanceDelta fees
    ) {
        // When accessing a public mapping that returns a struct, Solidity returns a tuple of values
        // not a struct that you can access fields from
        // So we need to use tuple destructuring to get the individual values
        (liquidity, lastFeePerLiquidity, claimablePrincipal, fees) = limitOrderManager.userPositions(poolId, positionKey, user);
    }

    // Helper functions for position key management
    function getBasePositionKey(
        int24 bottomTick,
        int24 topTick,
        bool isToken0
    ) public pure returns (bytes32) {
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
    ) public pure returns (bytes32) {
        return bytes32(
            uint256(uint24(bottomTick)) << 232 |
            uint256(uint24(topTick)) << 208 |
            uint256(nonce) << 8 |
            uint256(isToken0 ? 1 : 0)
        );
    }

    // Helper function to get claimable balances for a user in a pool
    function _getClaimableBalances(
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
        LimitOrderManager.PositionInfo[] memory positions = limitOrderManager.getUserPositions(user, poolId);
        
        // Iterate through each position and accumulate balances
        for (uint i = 0; i < positions.length; i++) {
            // Get position-specific balances
            LimitOrderManager.PositionBalances memory posBalances = 
                getPositionBalances(user, poolId, positions[i].positionKey);
            
            // Accumulate principals and fees
            token0Balance.principal += posBalances.principal0;
            token1Balance.principal += posBalances.principal1;
            token0Balance.fees += posBalances.fees0;
            token1Balance.fees += posBalances.fees1;
        }
        
        return (token0Balance, token1Balance);
    }

    /// @notice Converts a sqrtPrice to the nearest tick aligned with tick spacing
    /// @param sqrtPriceX96 The sqrt price in Q64.96 format
    /// @param key The pool key containing tick spacing information
    /// @return resultSqrtPriceX96 The sqrt price aligned to the nearest tick spacing (Q64.96 format)
    /// @return targetTick The tick corresponding to the nearest aligned price
    function convertSqrtPriceToTickAligned(
        uint160 sqrtPriceX96,
        PoolKey calldata key
    ) external pure returns (uint160 resultSqrtPriceX96, int24 targetTick) {
        // Validate that the sqrt price is within range
        require(sqrtPriceX96 >= TickMath.MIN_SQRT_PRICE, "SqrtPrice below minimum");
        require(sqrtPriceX96 <= TickMath.MAX_SQRT_PRICE, "SqrtPrice above maximum");

        // Get the tick that corresponds to this sqrtPrice
        int24 tickAtPrice = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // Get the min and max usable ticks based on tick spacing
        int24 tickSpacing = key.tickSpacing;
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        require(tickAtPrice >= minTick && tickAtPrice <= maxTick, "Tick out of range");

        // Round to the nearest tick spacing
        int24 tickLower = (tickAtPrice / tickSpacing) * tickSpacing;
        int24 tickUpper = tickLower + tickSpacing;
        
        // Determine which tick is closer
        targetTick = (tickAtPrice - tickLower < tickUpper - tickAtPrice) ? tickLower : tickUpper;

        // Ensure the target tick is also within valid range
        if (targetTick < minTick) targetTick = minTick;
        if (targetTick > maxTick) targetTick = maxTick;

        // Convert the aligned tick back to a sqrt price
        resultSqrtPriceX96 = TickMath.getSqrtPriceAtTick(targetTick);
        
        return (resultSqrtPriceX96, targetTick);
    }

    /// @notice Tick information including liquidity and token amounts
    struct TickInfo {
        int24 tick;
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 token0Amount;
        uint256 token1Amount;
        uint256 totalTokenAmountsinToken1;
        uint160 sqrtPrice;
    }

    function _calculateTickRange(
        int24 currentTick, 
        int24 tickSpacing, 
        uint24 numTicks
    ) internal pure returns (int24 startTick, uint256 totalTicks) {
        int24 alignedTick = (currentTick / tickSpacing) * tickSpacing;
        startTick = alignedTick - int24(numTicks);
        int24 endTick = alignedTick + int24(numTicks);
        
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        if (startTick < minTick) startTick = minTick;
        if (endTick > maxTick) endTick = maxTick;
        
        totalTicks = (uint24(endTick - startTick) / uint24(tickSpacing)) + 1;
    }

    /// @notice Calculate liquidity between ticks
    /// @param currentTick The current tick from slot0
    /// @param ticks Array of ordered tick indices
    /// @param liquidityNet Array of liquidityNet values for each tick
    /// @return liquidity Array of active liquidity values between ticks
    function _calculateLiquidityForTick(
        int24 currentTick,
        int24[] memory ticks,
        int128[] memory liquidityNet
    ) internal pure returns (uint128[] memory) {
        require(ticks.length > 0 && ticks.length == liquidityNet.length, "Invalid input arrays");
        
        // Result array contains liquidity between adjacent ticks
        uint128[] memory liquidity = new uint128[](ticks.length - 1);
        
        // Initialize with zero liquidity
        uint128 cumulativeLiquidity = 0;
        
        // First pass: accumulate liquidityNet for all ticks at or below current tick
        for (uint256 i = 0; i < ticks.length; i++) {
            if (ticks[i] <= currentTick) {
                if (liquidityNet[i] >= 0) {
                    cumulativeLiquidity += uint128(uint128(liquidityNet[i]));
                } else {
                    // Ensure we don't underflow if net liquidity is negative
                    if (uint128(-liquidityNet[i]) > cumulativeLiquidity) {
                        cumulativeLiquidity = 0;
                    } else {
                        cumulativeLiquidity -= uint128(uint128(-liquidityNet[i]));
                    }
                }
            }
        }
        
        // Second pass: calculate liquidity for each tick range
        for (uint256 i = 0; i < ticks.length - 1; i++) {
            int24 lowerTick = ticks[i];
            int24 upperTick = ticks[i + 1];
            
            // For ranges entirely below current tick
            if (upperTick <= currentTick) {
                liquidity[i] = cumulativeLiquidity;
                
                // Update liquidity after crossing the upper tick
                if (liquidityNet[i + 1] >= 0) {
                    cumulativeLiquidity += uint128(uint128(liquidityNet[i + 1]));
                } else {
                    if (uint128(-liquidityNet[i + 1]) > cumulativeLiquidity) {
                        cumulativeLiquidity = 0;
                    } else {
                        cumulativeLiquidity -= uint128(uint128(-liquidityNet[i + 1]));
                    }
                }
            }
            // For the range that contains the current tick
            else if (lowerTick <= currentTick && currentTick < upperTick) {
                liquidity[i] = cumulativeLiquidity;
            }
            // For ranges entirely above current tick
            else {
                // For tick ranges entirely above current price, calculate range liquidity
                uint128 rangeLiquidity = 0;
                
                // When current price is below this range's lower tick, we need to get the net liquidity
                // from all ticks up to (but not including) the lower tick of this range
                for (uint256 j = 0; j <= i; j++) {
                    if (liquidityNet[j] > 0) {
                        rangeLiquidity += uint128(uint128(liquidityNet[j]));
                    } else {
                        if (uint128(-liquidityNet[j]) > rangeLiquidity) {
                            rangeLiquidity = 0;
                        } else {
                            rangeLiquidity -= uint128(uint128(-liquidityNet[j]));
                        }
                    }
                }
                
                liquidity[i] = rangeLiquidity;
            }
        }
        
        return liquidity;
    }
    
    /// @notice Helper function to collect tick information
    /// @param poolManager The pool manager instance
    /// @param poolId The pool identifier
    /// @param startTick The starting tick
    /// @param tickSpacing The tick spacing
    /// @param totalTicks The total number of ticks to process
    /// @param ticks Output array for tick values
    /// @param liquidityNet Output array for liquidity net values
    /// @param liquidityGross Output array for liquidity gross values
    /// @param tickInfos Output array for tick information
    function _collectTickInfo(
        IPoolManager poolManager,
        PoolId poolId,
        int24 startTick,
        int24 tickSpacing,
        uint256 totalTicks,
        int24[] memory ticks,
        int128[] memory liquidityNet,
        uint128[] memory liquidityGross,
        TickInfo[] memory tickInfos
    ) internal view {
        for (uint256 i = 0; i < totalTicks; i++) {
            int24 tick = startTick + int24(uint24(i * uint24(tickSpacing)));
            ticks[i] = tick;
            
            // Get tick information from the pool
            (
                uint128 tickLiquidityGross,
                int128 tickLiquidityNet,
                ,  // feeGrowthOutside0X128 (not needed)
            ) = StateLibrary.getTickInfo(
                poolManager,
                poolId,
                tick
            );
            
            liquidityNet[i] = tickLiquidityNet;
            liquidityGross[i] = tickLiquidityGross;
            
            // Store tick data
            tickInfos[i].tick = tick;
            tickInfos[i].liquidityGross = tickLiquidityGross;
            tickInfos[i].liquidityNet = tickLiquidityNet;
            tickInfos[i].sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        }
    }

    /// @notice Helper function to process token amounts for ticks
    /// @param tickInfos Array of tick information
    /// @param ticks Array of tick values
    /// @param activeLiquidity Array of active liquidity values
    /// @param sqrtPriceX96 The current sqrt price
    /// @param currentTick The current tick
    /// @param totalTicks The total number of ticks
    function _processTickTokenAmounts(
        TickInfo[] memory tickInfos,
        int24[] memory ticks,
        uint128[] memory activeLiquidity,
        uint160 sqrtPriceX96,
        int24 currentTick,
        uint256 totalTicks
    ) internal pure {
        // Process token amounts for each tick range
        for (uint256 i = 0; i < totalTicks - 1; i++) {
            int24 lowerTick = ticks[i];
            int24 upperTick = ticks[i + 1];
            uint128 liquidityForRange = activeLiquidity[i];
            
            // Skip calculation if liquidity is zero
            if (liquidityForRange == 0) {
                tickInfos[i].token0Amount = 0;
                tickInfos[i].token1Amount = 0;
                tickInfos[i].totalTokenAmountsinToken1 = 0;
                continue;
            }
            
            // Calculate sqrtPrices for lower and upper ticks
            uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(lowerTick);
            uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(upperTick);
            
            uint256 token0Amount;
            uint256 token1Amount;
            
            // Determine token amounts based on current price position relative to the tick range
            if (currentTick < lowerTick) {
                // Current price is below range - position is entirely token0
                // When price is below the range, the position is all token0
                token0Amount = LiquidityAmounts.getAmount0ForLiquidity(
                    sqrtPriceLowerX96,
                    sqrtPriceUpperX96,
                    liquidityForRange
                );
                token1Amount = 0;
            } else if (currentTick >= upperTick) {
                // Current price is above range - position is entirely token1
                // When price is above the range, the position is all token1
                token0Amount = 0;
                token1Amount = LiquidityAmounts.getAmount1ForLiquidity(
                    sqrtPriceLowerX96,
                    sqrtPriceUpperX96,
                    liquidityForRange
                );
            } else {
                // Current price is within the range - position contains both tokens
                (token0Amount, token1Amount) = LiquidityAmounts.getAmountsForLiquidity(
                    sqrtPriceX96,
                    sqrtPriceLowerX96,
                    sqrtPriceUpperX96,
                    liquidityForRange
                );
            }
            
            // Update token amounts
            tickInfos[i].token0Amount = token0Amount;
            tickInfos[i].token1Amount = token1Amount;
            
            // Calculate totalTokenAmountsinToken1
            if (token0Amount > 0) {
                tickInfos[i].totalTokenAmountsinToken1 = FullMath.mulDiv(
                    token0Amount,
                    FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96),
                    1 << 96
                ) + token1Amount;
            } else {
                tickInfos[i].totalTokenAmountsinToken1 = token1Amount;
            }
        }
        
        // Handle the last tick if any
        if (totalTicks > 0) {
            uint256 lastIndex = totalTicks - 1;
            
            if (lastIndex > 0) {
                // Copy the previous tick's token amounts for simplicity
                tickInfos[lastIndex].token0Amount = 0;
                tickInfos[lastIndex].token1Amount = 0;
                tickInfos[lastIndex].totalTokenAmountsinToken1 = 0;
            } else {
                // If there's only one tick, use minimal values
                tickInfos[lastIndex].token0Amount = 0;
                tickInfos[lastIndex].token1Amount = 0;
                tickInfos[lastIndex].totalTokenAmountsinToken1 = 0;
            }
        }
    }

    /// @notice Get tick information for a range around the current tick
    /// @param poolId The pool identifier
    /// @param numTicks Number of ticks to include on each side of the current tick
    /// @return currentTick The current tick from slot0
    /// @return sqrtPriceX96 The sqrt price from slot0
    /// @return tickInfos Array of tick information
    function getTickInfosAroundCurrent(
        PoolId poolId,
        uint24 numTicks
    ) external view returns (int24 currentTick, uint160 sqrtPriceX96, TickInfo[] memory tickInfos) {
        // Get pool key from poolId
        PoolKey memory poolKey = poolIdToKey[poolId];
        require(poolKey.fee != 0, "Pool key not found");
        
        // Get current tick and sqrt price from slot0
        (sqrtPriceX96, currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
        
        // Calculate tick range
        (int24 startTick, uint256 totalTicks) = _calculateTickRange(
            currentTick, poolKey.tickSpacing, numTicks
        );

        // Create arrays
        tickInfos = new TickInfo[](totalTicks);
        int24[] memory ticks = new int24[](totalTicks);
        int128[] memory liquidityNet = new int128[](totalTicks);
        uint128[] memory liquidityGross = new uint128[](totalTicks);

        // Gather tick information
        _collectTickInfo(
            poolManager,
            poolId,
            startTick,
            poolKey.tickSpacing,
            totalTicks,
            ticks,
            liquidityNet,
            liquidityGross,
            tickInfos
        );
        
        // Calculate active liquidity between ticks
        uint128[] memory activeLiquidity = _calculateLiquidityForTick(
            currentTick, 
            ticks, 
            liquidityNet
        );
        
        // Process token amounts
        _processTickTokenAmounts(
            tickInfos,
            ticks,
            activeLiquidity,
            sqrtPriceX96,
            currentTick,
            totalTicks
        );
        
        return (currentTick, sqrtPriceX96, tickInfos);
    }

    /// @notice Get all positions for a user across all tracked pools with detailed information
    /// @param user The address of the user
    /// @return allPositions Array of detailed user position information
    function getAllUserPositions(address user) external view returns (
        DetailedUserPosition[] memory allPositions
    ) {
        // Calculate total positions count
        uint256 totalPositions = _countTotalUserPositions(user);
        
        // Allocate result array
        allPositions = new DetailedUserPosition[](totalPositions);
        
        // Fill positions array
        uint256 positionIndex = _fillPositionsArray(user, allPositions);
        
        // Resize the array if necessary (if some pools were skipped)
        if (positionIndex < totalPositions) {
            assembly {
                mstore(allPositions, positionIndex)
            }
        }
        
        return allPositions;
    }

    /// @notice Count total positions for a user across all pools
    /// @param user The user address
    /// @return totalPositions The total number of positions
    function _countTotalUserPositions(address user) internal view returns (uint256 totalPositions) {
        uint256 poolCount = poolIdBytes.length();
        
        for (uint256 i = 0; i < poolCount; i++) {
            PoolId poolId = PoolId.wrap(poolIdBytes.at(i));
            LimitOrderManager.PositionInfo[] memory positions = getUserPositionsForPool(user, poolId);
            totalPositions += positions.length;
        }
        
        return totalPositions;
    }

    /// @notice Fill the positions array with detailed information
    /// @param user The user address
    /// @param allPositions The array to populate
    /// @return positionIndex The number of positions filled
    function _fillPositionsArray(address user, DetailedUserPosition[] memory allPositions) internal view returns (uint256 positionIndex) {
        uint256 poolCount = poolIdBytes.length();
        
        for (uint256 i = 0; i < poolCount; i++) {
            PoolId poolId = PoolId.wrap(poolIdBytes.at(i));
            PoolKey memory poolKey = poolIdToKey[poolId];
            
            // Skip if poolKey is not set
            if (poolKey.fee == 0) continue;
            
            LimitOrderManager.PositionInfo[] memory positions = getUserPositionsForPool(user, poolId);
            
            // Skip if user has no positions in this pool
            if (positions.length == 0) continue;
            
            // Process the pool and get updated position index
            positionIndex = _processPoolPositions(user, poolId, poolKey, positions, allPositions, positionIndex);
        }
        
        return positionIndex;
    }

    /// @notice Process all positions for a specific pool
    /// @param user The user address
    /// @param poolId The pool ID
    /// @param poolKey The pool key
    /// @param positions The array of position info
    /// @param allPositions The result array to populate
    /// @param startIndex The starting index in the result array
    /// @return endIndex The ending index after processing
    function _processPoolPositions(
        address user,
        PoolId poolId,
        PoolKey memory poolKey,
        LimitOrderManager.PositionInfo[] memory positions,
        DetailedUserPosition[] memory allPositions,
        uint256 startIndex
    ) internal view returns (uint256 endIndex) {
        // Get pool state data
        PoolStateData memory poolData = _getPoolStateData(poolId, poolKey, user);
        
        // Process each position
        endIndex = startIndex;
        for (uint256 j = 0; j < positions.length; j++) {
            _processPosition(
                user,
                poolId,
                poolKey,
                positions[j].positionKey,
                poolData,
                allPositions,
                endIndex
            );
            endIndex++;
        }
        
        return endIndex;
    }

    /// @notice Get pool state data for a specific pool
    /// @param poolId The pool ID
    /// @param poolKey The pool key
    /// @param user The user address
    /// @return data The pool state data
    function _getPoolStateData(
        PoolId poolId,
        PoolKey memory poolKey,
        address user
    ) internal view returns (PoolStateData memory data) {
        // Get current pool state
        (data.sqrtPriceX96, data.currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
        
        // Get token information
        (data.token0Symbol, data.token0Decimals) = _getTokenInfo(poolKey.currency0);
        (data.token1Symbol, data.token1Decimals) = _getTokenInfo(poolKey.currency1);
        
        // Get user claimable balances
        (
            LimitOrderManager.ClaimableTokens memory token0Balance, 
            LimitOrderManager.ClaimableTokens memory token1Balance
        ) = _getClaimableBalances(user, poolKey);
        
        // Store balance data
        data.token0Principal = token0Balance.principal;
        data.token0Fees = token0Balance.fees;
        data.token1Principal = token1Balance.principal;
        data.token1Fees = token1Balance.fees;
        
        return data;
    }

    /// @notice Process a single position and add to result array
    /// @param user The user address
    /// @param poolId The pool ID
    /// @param poolKey The pool key
    /// @param positionKey The position key
    /// @param poolData The pool state data
    /// @param allPositions The result array to populate
    /// @param index The index in the result array
    function _processPosition(
        address user,
        PoolId poolId,
        PoolKey memory poolKey,
        bytes32 positionKey,
        PoolStateData memory poolData,
        DetailedUserPosition[] memory allPositions,
        uint256 index
    ) internal view {
        // Decode position key inline to reduce variables
        uint256 keyValue = uint256(positionKey);
        int24 bottomTick = int24(uint24(keyValue >> 232));
        int24 topTick = int24(uint24(keyValue >> 208));
        bool isToken0 = (keyValue & 1) == 1;
        
        // Create the position with minimal stack usage by calling helper functions
        _createBasicPositionInfo(allPositions, index, poolId, poolKey, poolData, bottomTick, topTick, isToken0);
        _addTickPriceInfo(allPositions, index, bottomTick, topTick, poolData.currentTick, poolData.sqrtPriceX96);
        _addBalanceInfo(allPositions, index, poolId, positionKey, user, poolData, bottomTick, topTick, isToken0);
    }

    /// @notice Add basic position information to a DetailedUserPosition
    function _createBasicPositionInfo(
        DetailedUserPosition[] memory positions,
        uint256 index,
        PoolId poolId, 
        PoolKey memory poolKey,
        PoolStateData memory poolData,
        int24 bottomTick,
        int24 topTick,
        bool isToken0
    ) internal pure {
        // Create a new DetailedUserPosition in the array with basic information
        positions[index].poolId = poolId;
        positions[index].currency0 = poolKey.currency0;
        positions[index].currency1 = poolKey.currency1;
        positions[index].token0Symbol = poolData.token0Symbol;
        positions[index].token1Symbol = poolData.token1Symbol;
        positions[index].token0Decimals = poolData.token0Decimals;
        positions[index].token1Decimals = poolData.token1Decimals;
        positions[index].isToken0 = isToken0;
        positions[index].bottomTick = bottomTick;
        positions[index].topTick = topTick;
        positions[index].currentTick = poolData.currentTick;
        positions[index].tickSpacing = poolKey.tickSpacing;
        positions[index].orderType = topTick - bottomTick > int24(poolKey.tickSpacing) ? "Range" : "Limit";
    }

    /// @notice Add tick price information to a DetailedUserPosition
    function _addTickPriceInfo(
        DetailedUserPosition[] memory positions,
        uint256 index,
        int24 bottomTick,
        int24 topTick,
        int24 currentTick,
        uint160 sqrtPriceX96
    ) internal view {
        // Calculate sqrt prices at ticks
        uint160 sqrtPriceBottomTickX96 = TickMath.getSqrtPriceAtTick(bottomTick);
        uint160 sqrtPriceTopTickX96 = TickMath.getSqrtPriceAtTick(topTick);
        
        positions[index].sqrtPrice = sqrtPriceX96;
        positions[index].sqrtPriceBottomTick = sqrtPriceBottomTickX96;
        positions[index].sqrtPriceTopTick = sqrtPriceTopTickX96;
    }

    /// @notice Add balance information to a DetailedUserPosition
    function _addBalanceInfo(
        DetailedUserPosition[] memory positions,
        uint256 index,
        PoolId poolId,
        bytes32 positionKey,
        address user,
        PoolStateData memory poolData,
        int24 bottomTick,
        int24 topTick,
        bool isToken0
    ) internal view {
        // Get user position data directly
        (uint128 liquidity, , BalanceDelta claimablePrincipal, ) = limitOrderManager.userPositions(poolId, positionKey, user);
        
        // Get position state to check if active
        (,,bool isActive,,) = limitOrderManager.positionState(poolId, positionKey);
        
        // Add liquidity and balance info
        positions[index].liquidity = liquidity;
        
        // Set total claimable balances for all positions
        positions[index].positionKey = positionKey;
        positions[index].totalCurrentToken0Principal = poolData.token0Principal;
        positions[index].totalCurrentToken1Principal = poolData.token1Principal;
        positions[index].feeRevenue0 = poolData.token0Fees;
        positions[index].feeRevenue1 = poolData.token1Fees;
        
        // Get position-specific balances
        LimitOrderManager.PositionBalances memory posBalances = 
            getPositionBalances(user, poolId, positionKey);
        
        // Set position-specific balances
        positions[index].positionToken0Principal = posBalances.principal0;
        positions[index].positionToken1Principal = posBalances.principal1;
        positions[index].positionFeeRevenue0 = posBalances.fees0;
        positions[index].positionFeeRevenue1 = posBalances.fees1;
        
        // Calculate execution amounts separately to reduce stack pressure
        _addExecutionAmounts(positions, index, bottomTick, topTick, liquidity, isToken0);
        
        // Set claimable flag to be exactly the opposite of isActive
        positions[index].claimable = !isActive;
        
        // Calculate order size based on isToken0
        uint160 sqrtPriceBottomTickX96 = positions[index].sqrtPriceBottomTick;
        uint160 sqrtPriceTopTickX96 = positions[index].sqrtPriceTopTick;
        
        if (isToken0) {
            // If isToken0 is true, orderSize is the amount of token0
            positions[index].orderSize = LiquidityAmounts.getAmount0ForLiquidity(
                sqrtPriceBottomTickX96,
                sqrtPriceTopTickX96,
                liquidity
            );
        } else {
            // If isToken0 is false, orderSize is the amount of token1
            positions[index].orderSize = LiquidityAmounts.getAmount1ForLiquidity(
                sqrtPriceBottomTickX96,
                sqrtPriceTopTickX96,
                liquidity
            );
        }
    }

    /// @notice Add execution amount information to a DetailedUserPosition
    function _addExecutionAmounts(
        DetailedUserPosition[] memory positions,
        uint256 index,
        int24 bottomTick,
        int24 topTick,
        uint128 liquidity,
        bool isToken0
    ) internal view {
        // Get sqrt prices only once
        uint160 sqrtPriceBottomTickX96 = TickMath.getSqrtPriceAtTick(bottomTick);
        uint160 sqrtPriceTopTickX96 = TickMath.getSqrtPriceAtTick(topTick);
        
        if (isToken0) {
            positions[index].totalToken0AtExecution = 0;
            positions[index].totalToken1AtExecution = LiquidityAmounts.getAmount1ForLiquidity(
                sqrtPriceBottomTickX96,
                sqrtPriceTopTickX96,
                liquidity
            );
        } else {
            positions[index].totalToken0AtExecution = LiquidityAmounts.getAmount0ForLiquidity(
                sqrtPriceBottomTickX96,
                sqrtPriceTopTickX96,
                liquidity
            );
            positions[index].totalToken1AtExecution = 0;
        }
    }

    /// @notice Get token symbol and decimals information
    /// @param currency The currency to get information for
    /// @return symbol The token symbol
    /// @return decimals The token decimals
    function _getTokenInfo(Currency currency) internal view returns (string memory symbol, uint8 decimals) {
        if (currency.isAddressZero()) {
            return ("NATIVE", 18);
        } else {
            ERC20MinimalInterface token = ERC20MinimalInterface(Currency.unwrap(currency));
            
            // Get token symbol and decimals directly
            // These calls may revert if the token doesn't implement them,
            // but most tokens used in Uniswap pools will have these functions
            symbol = token.symbol();
            decimals = token.decimals();
        }
    }

    /// @notice Get the minimum and maximum valid ticks for a limit order in a pool
    /// @param poolId The pool identifier
    /// @param isToken0 True if order is for token0, false for token1
    /// @return minTick The minimum valid tick for the order
    /// @return maxTick The maximum valid tick for the order
    function getMinAndMaxTick(PoolId poolId, bool isToken0) external view returns (int24 minTick, int24 maxTick) {
        // Get pool key from poolId
        PoolKey memory poolKey = poolIdToKey[poolId];
        
        // Get current tick from slot0
        (, int24 currentTick, ,) = StateLibrary.getSlot0(poolManager, poolId);
        
        // Get tick spacing from pool key
        int24 tickSpacing = poolKey.tickSpacing;
        
        // Calculate absolute min and max ticks
        int24 absoluteMinTick = TickMath.minUsableTick(tickSpacing);
        int24 absoluteMaxTick = TickMath.maxUsableTick(tickSpacing);
        
        if (isToken0) {
            // For token0 orders (buying token1), the price must go up
            // So the order must be placed above current tick
            minTick = (currentTick / tickSpacing + 1) * tickSpacing;
            maxTick = absoluteMaxTick;
        } else {
            // For token1 orders (buying token0), the price must go down
            // So the order must be placed below current tick
            minTick = absoluteMinTick;
            
            // Check if current tick is exactly on a tick spacing boundary
            if (currentTick % tickSpacing == 0) {
                maxTick = currentTick; // Use current tick as the max
            } else {
                // Otherwise use the next tick spacing below
                maxTick = (currentTick / tickSpacing - 1) * tickSpacing;
            }
        }
        
        return (minTick, maxTick);
    }

    /// @notice Calculate the scaled fee delta per liquidity unit
    /// @dev Used by the LimitOrderManager to update position fee tracking
    /// @param feeDelta The fee delta to scale
    /// @param liquidity The liquidity amount to divide by
    /// @return The scaled fee delta as a BalanceDelta
    function calculateScaledFeePerLiquidity(
        BalanceDelta feeDelta, 
        uint128 liquidity
    ) internal pure returns (BalanceDelta) {
        if(feeDelta == BalanceDelta.wrap(0) || liquidity == 0) return BalanceDelta.wrap(0);
        
        return toBalanceDelta(
            feeDelta.amount0() >= 0 
                ? int128(int256(FullMath.mulDiv(uint256(uint128(feeDelta.amount0())), 1e18, liquidity)))
                : -int128(int256(FullMath.mulDiv(uint256(uint128(-feeDelta.amount0())), 1e18, liquidity))),
            feeDelta.amount1() >= 0 
                ? int128(int256(FullMath.mulDiv(uint256(uint128(feeDelta.amount1())), 1e18, liquidity)))
                : -int128(int256(FullMath.mulDiv(uint256(uint128(-feeDelta.amount1())), 1e18, liquidity)))
        );
    }

    /// @notice Calculate the scaled user fee based on the fee difference and liquidity
    /// @dev Used by the LimitOrderManager to calculate user fees
    /// @param feeDiff The fee difference to scale
    /// @param liquidity The user's liquidity amount
    /// @return The scaled fee as a BalanceDelta
    function calculateScaledUserFee(
        BalanceDelta feeDiff, 
        uint128 liquidity
    ) internal pure returns (BalanceDelta) {
        if(feeDiff == BalanceDelta.wrap(0) || liquidity == 0) return BalanceDelta.wrap(0);
        
        return toBalanceDelta(
            feeDiff.amount0() >= 0 
                ? int128(int256(FullMath.mulDiv(uint256(uint128(feeDiff.amount0())), uint256(liquidity), 1e18)))
                : -int128(int256(FullMath.mulDiv(uint256(uint128(-feeDiff.amount0())), uint256(liquidity), 1e18))),
            feeDiff.amount1() >= 0 
                ? int128(int256(FullMath.mulDiv(uint256(uint128(feeDiff.amount1())), uint256(liquidity), 1e18)))
                : -int128(int256(FullMath.mulDiv(uint256(uint128(-feeDiff.amount1())), uint256(liquidity), 1e18)))
        );
    }

    // Add these helper functions before getPositionBalances
    function calculatePositionFee(
        PoolId poolId,
        int24 bottomTick,
        int24 topTick
    ) internal view returns (uint256 fee0, uint256 fee1) {
        (uint128 liquidityBefore, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = 
            StateLibrary.getPositionInfo(
                poolManager,
                poolId,
                address(limitOrderManager),
                bottomTick,
                topTick,
                bytes32(0) // salt
            );

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = StateLibrary.getFeeGrowthInside(
            poolManager,
            poolId,
            bottomTick,
            topTick
        );

        uint256 feeGrowthDelta0 = 0;
        uint256 feeGrowthDelta1 = 0;

        unchecked {
            if (feeGrowthInside0X128 != feeGrowthInside0LastX128) {
                feeGrowthDelta0 = feeGrowthInside0X128 - feeGrowthInside0LastX128;
            }
            if (feeGrowthInside1X128 != feeGrowthInside1LastX128) {
                feeGrowthDelta1 = feeGrowthInside1X128 - feeGrowthInside1LastX128;
            }
            fee0 = FullMath.mulDiv(feeGrowthDelta0, liquidityBefore, 1 << 128);
            fee1 = FullMath.mulDiv(feeGrowthDelta1, liquidityBefore, 1 << 128); 
        }

        return (fee0, fee1);
    }

    function getUserProportionateFees(
        uint128 liquidity,
        uint128 totalLiquidity,
        BalanceDelta fees,
        BalanceDelta lastFeePerLiquidity,
        BalanceDelta feePerLiquidity,
        uint256 globalFees0,
        uint256 globalFees1
    ) internal pure returns (BalanceDelta) {
        if (liquidity == 0) return fees;
        if (totalLiquidity == 0) return fees;

        int128 feePerLiq0 = int128(int256(FullMath.mulDiv(uint256(globalFees0), uint256(1e18), uint256(totalLiquidity))));
        int128 feePerLiq1 = int128(int256(FullMath.mulDiv(uint256(globalFees1), uint256(1e18), uint256(totalLiquidity))));
        
        BalanceDelta newTotalFeePerLiquidity = feePerLiquidity + toBalanceDelta(feePerLiq0, feePerLiq1);
        BalanceDelta feeDiff = newTotalFeePerLiquidity - lastFeePerLiquidity;
        
        int128 userFee0 = feeDiff.amount0() >= 0
            ? int128(int256(FullMath.mulDiv(uint256(uint128(feeDiff.amount0())), uint256(liquidity), uint256(1e18))))
            : -int128(int256(FullMath.mulDiv(uint256(uint128(-feeDiff.amount0())), uint256(liquidity), uint256(1e18))));
        int128 userFee1 = feeDiff.amount1() >= 0
            ? int128(int256(FullMath.mulDiv(uint256(uint128(feeDiff.amount1())), uint256(liquidity), uint256(1e18))))
            : -int128(int256(FullMath.mulDiv(uint256(uint128(-feeDiff.amount1())), uint256(liquidity), uint256(1e18))));
        
        return fees + toBalanceDelta(userFee0, userFee1);
    }

    // Add this struct definition after the existing struct definitions
    struct PositionParams {
        ILimitOrderManager.UserPosition position;
        ILimitOrderManager.PositionState posState;
        IPoolManager poolManager;
        PoolId poolId;
        int24 bottomTick;
        int24 topTick;
        bool isToken0;
        uint256 feeDenom;
        uint256 hookFeePercentage;
    }

    // Add this function before getPositionBalances
    function _constructPositionParams(
        bytes32 positionKey,
        address user,
        PoolId poolId
    ) internal view returns (PositionParams memory) {
        (int24 bottomTick, int24 topTick, bool isToken0, ) = decodePositionKey(positionKey);
        
        return PositionParams({
            position: userPositions(poolId, positionKey, user),
            posState: positionState(poolId, positionKey),
            poolManager: poolManager,
            poolId: poolId,
            bottomTick: bottomTick,
            topTick: topTick,
            isToken0: isToken0,
            feeDenom: limitOrderManager.FEE_DENOMINATOR(),
            hookFeePercentage: limitOrderManager.hook_fee_percentage()
        });
    }
    
    // Helper function to get user position data
    function userPositions(
        PoolId poolId,
        bytes32 positionKey,
        address user
    ) internal view returns (ILimitOrderManager.UserPosition memory position) {
        (uint128 liquidity, BalanceDelta lastFeePerLiquidity, BalanceDelta claimablePrincipal, BalanceDelta fees) = 
            limitOrderManager.userPositions(poolId, positionKey, user);
            
        position.liquidity = liquidity;
        position.lastFeePerLiquidity = lastFeePerLiquidity;
        position.claimablePrincipal = claimablePrincipal;
        position.fees = fees;
    }
    
    // Helper function to get position state data
    function positionState(
        PoolId poolId,
        bytes32 positionKey
    ) internal view returns (ILimitOrderManager.PositionState memory posState) {
        (BalanceDelta feePerLiquidity, uint128 totalLiquidity, bool isActive, bool isWaitingKeeper, uint256 currentNonce) = 
            limitOrderManager.positionState(poolId, positionKey);
            
        posState.feePerLiquidity = feePerLiquidity;
        posState.totalLiquidity = totalLiquidity;
        posState.isActive = isActive;
        posState.isWaitingKeeper = isWaitingKeeper;
        posState.currentNonce = currentNonce;
    }

    // Replace the existing getPositionBalances function with this updated version
    function getPositionBalances(
        address user,
        PoolId poolId,
        bytes32 positionKey
    ) public view returns (LimitOrderManager.PositionBalances memory balances) {
        // Use the structured approach to reduce stack variables
        PositionParams memory params = _constructPositionParams(positionKey, user, poolId);
        
        // Calculate principals based on active status
        if (!params.posState.isActive) {
            if (params.isToken0) {
                balances.principal1 = LiquidityAmounts.getAmount1ForLiquidity(
                    TickMath.getSqrtPriceAtTick(params.bottomTick),
                    TickMath.getSqrtPriceAtTick(params.topTick),
                    params.position.liquidity
                );
            } else {
                balances.principal0 = LiquidityAmounts.getAmount0ForLiquidity(
                    TickMath.getSqrtPriceAtTick(params.bottomTick),
                    TickMath.getSqrtPriceAtTick(params.topTick),
                    params.position.liquidity
                );
            }
        } else {
            // Get current tick price directly from StateLibrary
            (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(params.poolManager, params.poolId);
            (balances.principal0, balances.principal1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96, 
                TickMath.getSqrtPriceAtTick(params.bottomTick),
                TickMath.getSqrtPriceAtTick(params.topTick),
                params.position.liquidity
            );
        }
        
        // Calculate fees
        BalanceDelta fees;
        
        if (params.posState.isActive) {
            // For active positions, calculate fees based on pool state
            (uint256 fee0Global, uint256 fee1Global) = calculatePositionFee(
                params.poolId, 
                params.bottomTick, 
                params.topTick
            );
            
            fees = getUserProportionateFees(
                params.position.liquidity,
                params.posState.totalLiquidity,
                params.position.fees,
                params.position.lastFeePerLiquidity,
                params.posState.feePerLiquidity,
                fee0Global,
                fee1Global
            );
        } else {
            // For inactive positions, calculate based on fee difference
            fees = params.position.fees;
            if (params.position.liquidity != 0) {
                BalanceDelta feeDiff = params.posState.feePerLiquidity - params.position.lastFeePerLiquidity;
                fees = params.position.fees + calculateScaledUserFee(feeDiff, params.position.liquidity);
            }
        }
        
        // Apply hook fees
        if (fees.amount0() > 0) {
            balances.fees0 = (uint256(uint128(fees.amount0())) * 
                             (params.feeDenom - params.hookFeePercentage)) / 
                             params.feeDenom;
        }
        
        if (fees.amount1() > 0) {
            balances.fees1 = (uint256(uint128(fees.amount1())) * 
                             (params.feeDenom - params.hookFeePercentage)) / 
                             params.feeDenom;
        }
        
        return balances;
    }
}


/// @notice Extended position info that includes pool details
/// @dev Used by getUserPositions to return comprehensive position data
struct UserPositionWithPool {
    PoolId poolId;
    PoolKey poolKey;
    bytes32 positionKey;
    int24 bottomTick;
    int24 topTick;
    bool isToken0;
    uint128 liquidity;
    BalanceDelta fees;
}

/// @notice Helper struct to hold pool state data to reduce stack variables
struct PoolStateData {
    uint160 sqrtPriceX96;
    int24 currentTick;
    string token0Symbol;
    string token1Symbol;
    uint8 token0Decimals;
    uint8 token1Decimals;
    uint256 token0Principal;
    uint256 token0Fees;
    uint256 token1Principal;
    uint256 token1Fees;
}

/// @notice Detailed position information including pool and token details
/// @dev Used by getAllUserPositions to return comprehensive position data
struct DetailedUserPosition {
    PoolId poolId;
    bytes32 positionKey;
    Currency currency0;
    Currency currency1;
    string token0Symbol;
    string token1Symbol;
    uint8 token0Decimals;
    uint8 token1Decimals;
    bool isToken0;
    int24 bottomTick;
    int24 topTick;
    int24 currentTick;
    int24 tickSpacing;
    string orderType;
    uint160 sqrtPrice;
    uint160 sqrtPriceBottomTick;
    uint160 sqrtPriceTopTick;
    uint128 liquidity;
    uint256 positionToken0Principal;  // This position's specific token0 principal
    uint256 positionToken1Principal;  // This position's specific token1 principal
    uint256 positionFeeRevenue0;      // This position's specific token0 fees
    uint256 positionFeeRevenue1;      // This position's specific token1 fees
    uint256 totalCurrentToken0Principal; // Total for all user positions in this pool
    uint256 totalCurrentToken1Principal; // Total for all user positions in this pool
    uint256 feeRevenue0;              // Total fees for all user positions in this pool
    uint256 feeRevenue1;              // Total fees for all user positions in this pool
    uint256 totalToken0AtExecution;
    uint256 totalToken1AtExecution;
    uint256 orderSize;
    bool claimable;
}