// SPDX-License-Identifier: BSL
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ILimitOrderManager} from "./ILimitOrderManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "./CurrencySettler.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

library CallbackHandler {
    using CurrencySettler for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    BalanceDelta public constant ZERO_DELTA = BalanceDelta.wrap(0);

    event AmountsClaimed(Currency currency, uint256 principalAmount, uint256 feeAmount, uint256 treasury);
    event FailedTransferSentToTreasury(Currency currency, address originalRecipient, uint256 amount);

    // Storage struct to handle state management
    struct CallbackState {
        IPoolManager poolManager;
        address treasury;
        uint256 hookFeePercentage;
        uint256 feeDenominator;
    }

    /// @notice Handles the callback for claiming order proceeds and fees
    /// @dev Processes token transfers for both principal and fee amounts for token0 and token1
    ///      Converts balance deltas to uint256 and handles token transfers to user and treasury
    /// @param state The callback state containing pool manager and fee settings
    /// @param claimData Struct containing claim details including principal, fees, and user address
    /// @return bytes Encoded return value (always 0 for claim callbacks)
    function handleClaimOrderCallback(
        CallbackState storage state,
        ILimitOrderManager.ClaimOrderCallbackData memory claimData
    ) internal returns (bytes memory) {
        _handleTokenTransfersAndFees(
            state,
            // claimData.key,
            uint256(uint128(claimData.principal.amount0())),
            uint256(uint128(claimData.fees.amount0())),
            claimData.key.currency0,
            claimData.user
        );

        _handleTokenTransfersAndFees(
            state,
            // claimData.key,
            uint256(uint128(claimData.principal.amount1())),
            uint256(uint128(claimData.fees.amount1())),
            claimData.key.currency1,
            claimData.user
        );

        // Clear any remaining dust amounts
        _clearExactDelta(state, claimData.key.currency0);
        _clearExactDelta(state, claimData.key.currency1);

        return abi.encode(0);
    }

    /// @notice Handles the callback for canceling a limit order
    /// @dev Burns the order's liquidity position and returns the balance changes
    ///      The returned deltas are used to update position state and handle refunds
    /// @param state The callback state containing pool manager reference
    /// @param cancelData Struct containing order details needed for cancellation (ticks, liquidity)
    /// @return bytes ABI encoded balance deltas:
    ///         - callerDelta: Token amounts to return to user
    ///         - feeDelta: Accumulated fees for the position
    function handleCancelOrderCallback(
        CallbackState storage state,
        ILimitOrderManager.CancelOrderCallbackData memory cancelData
    ) internal returns (bytes memory) {
        (BalanceDelta callerDelta, BalanceDelta feeDelta) = _burnLimitOrder(
            state,
            cancelData.key,
            cancelData.bottomTick,
            cancelData.topTick,
            cancelData.liquidity
        );

        // Clear any remaining dust amounts
        _clearExactDelta(state, cancelData.key.currency0);
        _clearExactDelta(state, cancelData.key.currency1);

        return abi.encode(callerDelta, feeDelta);
    }

    /// @notice Burns liquidity for a limit order and mints corresponding tokens to the LimitOrderManager
    /// @dev Removes liquidity from the pool and handles token settlement
    ///      Converts negative balance deltas to positive amounts for token minting
    ///      Only mints tokens when the delta amount is positive
    /// @param state The callback state containing pool manager reference
    /// @param key The pool key identifying the specific Uniswap V4 pool
    /// @param bottomTick The lower tick boundary of the position
    /// @param topTick The upper tick boundary of the position
    /// @param liquidity The amount of liquidity to burn
    /// @return callerDelta The net balance changes for the position owner
    /// @return feeDelta The accumulated fees for the position
    function _burnLimitOrder(
        CallbackState storage state,
        PoolKey memory key,
        int24 bottomTick,
        int24 topTick,
        uint128 liquidity
    ) internal returns (BalanceDelta callerDelta, BalanceDelta feeDelta) {
        (callerDelta, feeDelta) = state.poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: bottomTick,
                tickUpper: topTick,
                liquidityDelta: -int128(liquidity),
                salt: bytes32(0)
            }),
            ""
        );

        int128 delta0 = callerDelta.amount0();
        int128 delta1 = callerDelta.amount1();
        
        if (delta0 > 0) {
            state.poolManager.mint(
                address(this), 
                uint256(uint160(Currency.unwrap(key.currency0))), 
                uint256(int256(delta0))
            );
        }
        
        if (delta1 > 0) {
            state.poolManager.mint(
                address(this), 
                uint256(uint160(Currency.unwrap(key.currency1))), 
                uint256(int256(delta1))
            );
        }
    }

    /// @notice Handles the callback for creating one or more limit orders
    /// @dev Processes each order by:
    ///      1. Settling input tokens with the pool manager
    ///      2. Adding liquidity to create the limit order position
    ///      3. Handling any fees generated during creation
    /// @param state The callback state containing pool manager and fee settings
    /// @param callbackData Struct containing order details including:
    ///        - orders: Array of order parameters (ticks, amounts, liquidity)
    ///        - isToken0: Whether orders are for token0 or token1
    ///        - key: Pool key identifying the specific pool
    /// @return bytes ABI encoded arrays of balance deltas:
    ///         - deltas: Array of position balance changes
    ///         - feeDeltas: Array of fee amounts generated
    function handleCreateOrdersCallback(
        CallbackState storage state,
        ILimitOrderManager.CreateOrdersCallbackData memory callbackData
    ) internal returns(bytes memory) {
        // BalanceDelta[] memory deltas = new BalanceDelta[](callbackData.orders.length);
        BalanceDelta[] memory feeDeltas = new BalanceDelta[](callbackData.orders.length);
        BalanceDelta accumulatedMintFees;
        for (uint256 i = 0; i < callbackData.orders.length; i++) {
            ILimitOrderManager.OrderInfo memory order = callbackData.orders[i];
            callbackData.isToken0 ? 
                callbackData.key.currency0.settle(state.poolManager, address(this), order.amount, false) :
                callbackData.key.currency1.settle(state.poolManager, address(this), order.amount, false);
            (, BalanceDelta feeDelta) = state.poolManager.modifyLiquidity(
                callbackData.key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: order.bottomTick,
                    tickUpper: order.topTick,
                    liquidityDelta: int256(uint256(order.liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            // deltas[i] = delta;
            feeDeltas[i] = feeDelta;
            // Accumulate fee details if greater than zero
            if (feeDelta != ZERO_DELTA) {
                accumulatedMintFees = accumulatedMintFees + feeDelta;
            }
        }
        _mintFeesToHook(state, callbackData.key, accumulatedMintFees);

        // Clear any remaining dust amounts
        _clearExactDelta(state, callbackData.key.currency0);
        _clearExactDelta(state, callbackData.key.currency1);
        
        return abi.encode(feeDeltas);
    }

    // Private helper functions
    function _mintFeesToHook(
        CallbackState storage state,
        PoolKey memory key,
        BalanceDelta feeDelta
    ) private {
        int128 fee0 = feeDelta.amount0();
        int128 fee1 = feeDelta.amount1();
        
        if (fee0 > 0) {
            state.poolManager.mint(
                address(this), 
                uint256(uint160(Currency.unwrap(key.currency0))), 
                uint256(int256(fee0))
            );
        }
        
        if (fee1 > 0) {
            state.poolManager.mint(
                address(this), 
                uint256(uint160(Currency.unwrap(key.currency1))), 
                uint256(int256(fee1))
            );
        }
    }

    function _handleTokenTransfersAndFees(
        CallbackState storage state,
        uint256 principalAmount,
        uint256 feeAmount,
        Currency currency,
        address user
    ) private {
        if (principalAmount == 0 && feeAmount == 0) return;
        
        uint256 currencyId = uint256(uint160(Currency.unwrap(currency)));
        uint256 treasuryFee = FullMath.mulDiv(feeAmount, state.hookFeePercentage, state.feeDenominator);
        uint256 userAmount = principalAmount + (feeAmount - treasuryFee);
        
        if (userAmount > 0) {
            state.poolManager.burn(address(this), currencyId, userAmount);
            
            // Try to transfer tokens to user
            try state.poolManager.take(currency, user, userAmount) {
                emit AmountsClaimed(currency, principalAmount, feeAmount - treasuryFee, treasuryFee);
            } catch {
                // On failure, send to treasury instead and log the intended recipient
                state.poolManager.take(currency, state.treasury, userAmount);
                emit FailedTransferSentToTreasury(currency, user, userAmount);
            }
        }
        
        if (treasuryFee > 0) {
            state.poolManager.burn(address(this), currencyId, treasuryFee);
            state.poolManager.take(currency, state.treasury, treasuryFee);
        }
    }

    // Helper function to clear the exact delta amount to avoid CurrencyNotSettled errors
    function _clearExactDelta(CallbackState storage state, Currency currency) private {
        int256 delta = state.poolManager.currencyDelta(address(this), currency);
        if (delta > 0) {
            state.poolManager.clear(currency, uint256(delta));
        }
    }
}