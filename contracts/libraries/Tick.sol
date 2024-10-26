// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import './LowGasSafeMath.sol';
import './SafeCast.sol';

import './TickMath.sol';
import './LiquidityMath.sol';

/// @title Tick
/// @notice Contains functions for managing tick processes and relevant calculations
library Tick {
    using LowGasSafeMath for int256;
    using SafeCast for int256;

    // info stored for each initialized individual tick
    struct Info {

        // 比方说有两个 position 中的流动性相等，例如L=500，并且这两个 position 同时引用了一个 tick，其中一个为lower tick ，另一个为upper tick，那么对于这个 tick，它的 liquidityNet=+500-500=0。而liquidityGross=500+500=1000
        // 当价格变动导致 tickcurent 越过一个 position 的 lowerupper tick 时，我们需要根据 tick 中记录的值来更新当前价格所对应的总体流动性。
        // 假设 position 的流动性值为 ΔL，会有以下四种情况:
        // 价格上涨，从左到右穿过一个 lower tick: liquidityNet = liquidityNet + ΔL;
        // 价格上涨，从左到右穿过一个 upper tick: liquidityNet = liquidityNet - ΔL;
        // 价格下降，从右到左穿过一个 upper tick: liquidityNet = liquidityNet + ΔL;
        // 价格下降，从右到左穿过一个 lower tick: liquidityNet = liquidityNet - ΔL;

        // the total position liquidity that references this tick
        // 此tick的总头寸流动性
        uint128 liquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        // delta L
        // 当tick从左到右（从右到左）越过时增加（减少）的净流动数量，为正数时说明从左到右是增加，为负数时说明从左到右是减少
        int128 liquidityNet;
        // fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        // 此tick另一侧每单位流动资金的费用增长（相对于当前tick）
        // 仅具有相对意义，而不是绝对意义-该值取决于何时初始化tick
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        // the cumulative tick value on the other side of the tick
        // 在tick的另一边的累积tick值
        int56 tickCumulativeOutside;
        // the seconds per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        // 在此tick的另一侧每单位流动性的秒数（相对于当前tick）
        uint160 secondsPerLiquidityOutsideX128;
        // the seconds spent on the other side of the tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        // 在此tick的另一侧的时间花费（相对于当前tick）
        uint32 secondsOutside;
        // true iff the tick is initialized, i.e. the value is exactly equivalent to the expression liquidityGross != 0
        // these 8 bits are set to prevent fresh sstores when crossing newly initialized ticks
        // true如果tick被初始化，即该值完全等同于表达式liquidityGross != 0
        // 设置这8位是为了防止在越过新初始化的tick时刷新sstores
        bool initialized;
    }

    /// @notice Derives max liquidity per tick from given tick spacing
    /// 从给定的tick spacingd得出每个tick的最大流动性
    /// @dev Executed within the pool constructor
    /// @param tickSpacing The amount of required tick separation, realized in multiples of `tickSpacing`
    ///     e.g., a tickSpacing of 3 requires ticks to be initialized every 3rd tick i.e., ..., -6, -3, 0, 3, 6, ...
    /// @return The max liquidity per tick
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128) {
        // 计算tickSpacing下的最小tick
        // 假设tickSpacing = 10，TickMath.MIN_TICK = -887272，minTick = -887270
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;  
        // 计算tickSpacing下的最大tick
        // 假设tickSpacing = 10，TickMath.MAX_TICK = 887272，maxTick = 887270
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;  
        // 计算tick区间内的tick数量 
        // 根据上面假设的计算，numTicks = 177456
        uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1; 
        return type(uint128).max / numTicks;
    }

    /// @notice Retrieves fee growth data
    /// 检索费用增长数据
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @param tickCurrent The current tick
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
    /// @return feeGrowthInside0X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries
    /// @return feeGrowthInside1X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries
    function getFeeGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        Info storage lower = self[tickLower];
        Info storage upper = self[tickUpper];

        // calculate fee growth below
        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        if (tickCurrent >= tickLower) {
            feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
        } else {
            feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
        }

        // calculate fee growth above
        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        if (tickCurrent < tickUpper) {
            feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
        } else {
            feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
        }

        feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
        feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
    }

    /// @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa
    /// 更新一个tick，如果tick从初始化翻转到未初始化，则返回true，反之亦然
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The tick that will be updated
    /// @param tickCurrent The current tick
    /// @param liquidityDelta A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left)
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
    /// @param secondsPerLiquidityCumulativeX128 The all-time seconds per max(1, liquidity) of the pool
    /// @param tickCumulative The tick * time elapsed since the pool was first initialized
    /// @param time The current block timestamp cast to a uint32
    /// @param upper true for updating a position's upper tick, or false for updating a position's lower tick
    /// @param maxLiquidity The maximum liquidity allocation for a single tick
    /// @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa
    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time,
        bool upper,
        uint128 maxLiquidity
    ) internal returns (bool flipped) {
        Tick.Info storage info = self[tick];

        uint128 liquidityGrossBefore = info.liquidityGross; // 获取tick更新之前的流动性
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta); // tick原来的流动性加上新增的流动性

        require(liquidityGrossAfter <= maxLiquidity, 'LO'); // tick上的流动性要小于每个tick上的最大流动性

        // liquidityGrossAfter == 0，liquidityGrossBefore == 0，flipped = (true != true) = false
        // liquidityGrossAfter != 0，liquidityGrossBefore == 0，flipped = (false != true) = ture
        // liquidityGrossAfter == 0，liquidityGrossBefore != 0，flipped = (true != false) = ture
        // liquidityGrossAfter != 0，liquidityGrossBefore != 0，flipped = (false != false) = false
        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) { // 如果tick更新之前的liquidityGross为0，说明此次为初始化操作
            // by convention, we assume that all growth before a tick was initialized happened _below_ the tick
            // 我们假定此 tick 初始化前，所有交易都发生在低于 tick 价格的范围中。这个假设并不一定复合实际情况，但是在最终的计算中，因为涉及到 lower/upper tick 的减法，这样的假设并不会对最终结果造成误差。
            if (tick <= tickCurrent) {
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
                info.secondsPerLiquidityOutsideX128 = secondsPerLiquidityCumulativeX128;
                info.tickCumulativeOutside = tickCumulative;
                info.secondsOutside = time;
            }
            info.initialized = true;
        }

        info.liquidityGross = liquidityGrossAfter;

        // when the lower (upper) tick is crossed left to right (right to left), liquidity must be added (removed)
        // 当lower（upper）tick从左到右（从右到左）y越过时，必须添加（删除）流动性。
        info.liquidityNet = upper
            ? int256(info.liquidityNet).sub(liquidityDelta).toInt128()
            : int256(info.liquidityNet).add(liquidityDelta).toInt128();
    }

    /// @notice Clears tick data
    /// @param self The mapping containing all initialized tick information for initialized ticks
    /// @param tick The tick that will be cleared
    function clear(mapping(int24 => Tick.Info) storage self, int24 tick) internal {
        delete self[tick];
    }

    /// @notice Transitions to next tick as needed by price movement
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The destination tick of the transition
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
    /// @param secondsPerLiquidityCumulativeX128 The current seconds per liquidity
    /// @param tickCumulative The tick * time elapsed since the pool was first initialized
    /// @param time The current block.timestamp
    /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
    function cross(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time
    ) internal returns (int128 liquidityNet) {
        Tick.Info storage info = self[tick];
        info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
        info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
        info.secondsPerLiquidityOutsideX128 = secondsPerLiquidityCumulativeX128 - info.secondsPerLiquidityOutsideX128;
        info.tickCumulativeOutside = tickCumulative - info.tickCumulativeOutside;
        info.secondsOutside = time - info.secondsOutside;
        liquidityNet = info.liquidityNet;
    }
}
