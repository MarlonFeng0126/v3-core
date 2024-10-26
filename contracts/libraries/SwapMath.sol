// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import './FullMath.sol';
import './SqrtPriceMath.sol';

/// @title Computes the result of a swap within ticks
/// 计算ticks内交换的结果
/// @notice Contains methods for computing the result of a swap within a single tick price range, i.e., a single tick.
library SwapMath {
    /// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
    /// 在给定交换参数的情况下，计算交换一些amount in或者amount out的结果
    /// @dev The fee, plus the amount in, will never exceed the amount remaining if the swap's `amountSpecified` is positive
    /// 如果交换的'amountSpecified'为正数，则fee加上amount in金额将永远不会超过剩余金额
    /// @param sqrtRatioCurrentX96 The current sqrt price of the pool
    /// @param sqrtRatioTargetX96 The price that cannot be exceeded, from which the direction of the swap is inferred
    /// @param liquidity The usable liquidity
    /// @param amountRemaining How much input or output amount is remaining to be swapped in/out
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip
    /// @return sqrtRatioNextX96 The price after swapping the amount in/out, not to exceed the price target
    /// @return amountIn The amount to be swapped in, of either token0 or token1, based on the direction of the swap
    /// @return amountOut The amount to be received, of either token0 or token1, based on the direction of the swap
    /// @return feeAmount The amount of input that will be taken as a fee
    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    )
        internal
        pure
        returns (
            uint160 sqrtRatioNextX96,
            uint256 amountIn,
            uint256 amountOut,
            uint256 feeAmount
        )
    {
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96; // 当前价格>=目标价格，zeroForOne为ture，说明是token0换token1
        bool exactIn = amountRemaining >= 0;

        if (exactIn) {
            // 计算除去手续费后的待交换的剩余数量 (amountRemaining * (1e6 - feePips)) / 1e6
            uint256 amountRemainingLessFee = FullMath.mulDiv(uint256(amountRemaining), 1e6 - feePips, 1e6);
            // 计算需要多少数量
            amountIn = zeroForOne
                ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
            // 如果计算除去手续费后的待交换的剩余数量大于或者等于实际需要的数量，则可能还有剩余的数量，把交换后的目标价格赋值给当前价格
            // 否则计算除去手续费后的待交换的剩余数量小于等于实际需要的数量，说明输入的数量不够，交换后达不到目标价格，则需要计算交换后的价格
            if (amountRemainingLessFee >= amountIn) sqrtRatioNextX96 = sqrtRatioTargetX96;
            else
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    amountRemainingLessFee,
                    zeroForOne
                );
        } else {
            amountOut = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
            if (uint256(-amountRemaining) >= amountOut) sqrtRatioNextX96 = sqrtRatioTargetX96;
            else
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    uint256(-amountRemaining),
                    zeroForOne
                );
        }

        bool max = sqrtRatioTargetX96 == sqrtRatioNextX96;

        // get the input/output amounts
        if (zeroForOne) {
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false);
        } else {
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
        }

        // cap the output amount to not exceed the remaining output amount
        if (!exactIn && amountOut > uint256(-amountRemaining)) {
            amountOut = uint256(-amountRemaining);
        }

        if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
            // we didn't reach the target, so take the remainder of the maximum input as fee
            feeAmount = uint256(amountRemaining) - amountIn;
        } else {
            feeAmount = FullMath.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
        }
    }
}
