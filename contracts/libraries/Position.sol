// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import './FullMath.sol';
import './FixedPoint128.sol';
import './LiquidityMath.sol';

/// @title Position 头寸
/// @notice Positions represent an owner address' liquidity between a lower and upper tick boundary
/// 头寸代表所有者地址的流动性之间的下限和上限的边界
/// @dev Positions store additional state for tracking fees owed to the position
/// 头寸存储额外的状态，用于跟踪头寸的所欠费用
library Position {
    // info stored for each user's position
    struct Info {
        // the amount of liquidity owned by this position
        // 头寸的总流动性
        uint128 liquidity;
        // fee growth per unit of liquidity as of the last update to liquidity or fees owed
        // 截至最后一次更新流动性或所欠费用时，每单位流动性的费用增长
        // 对于每个position，记录了此 position 内的手续费总额 feeGrowthInside0LastX128和 feeGrowthInsidelLastX128，这个值不需要每次都更新，它只会在 position 发生变动，或者用户提取手续费时更新
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // the fees owed to the position owner in token0/token1
        // 欠头寸所有者的费用
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /// @notice Returns the Info struct of a position, given an owner and position boundaries
    /// 给定所有者和头寸边界，返回头寸的Info结构体
    /// @param self The mapping containing all user positions 包含所有用户头寸的映射
    /// @param owner The address of the position owner 头寸所有者的地址
    /// @param tickLower The lower tick boundary of the position 头寸tick的下限
    /// @param tickUpper The upper tick boundary of the position 头寸tick的上限
    /// @return position The position info struct of the given owners' position
    function get(
        mapping(bytes32 => Info) storage self,
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (Position.Info storage position) {
        position = self[keccak256(abi.encodePacked(owner, tickLower, tickUpper))];
    }

    /// @notice Credits accumulated fees to a user's position
    /// 将累积的费用记入用户的头寸
    /// @param self The individual position to update 
    /// 要更新的单独的头寸
    /// @param liquidityDelta The change in pool liquidity as a result of the position update 
    /// 由于头寸更新导致的池流动性变化
    /// @param feeGrowthInside0X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries
    /// 在头寸的tick范围内，每单位流动性的token0的历史费用增长
    /// @param feeGrowthInside1X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries
    /// 在头寸的tick范围内，每单位流动性的token1的历史费用增长
    function update(
        Info storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal {
        Info memory _self = self;

        uint128 liquidityNext;
        if (liquidityDelta == 0) {
            require(_self.liquidity > 0, 'NP'); // disallow pokes for 0 liquidity positions
            liquidityNext = _self.liquidity;
        } else {
            liquidityNext = LiquidityMath.addDelta(_self.liquidity, liquidityDelta);
        }

        // calculate accumulated fees 计算累积的手续费
        // (feeGrowthInside0X128 - _self.feeGrowthInside0LastX128) * _self.liquidity
        uint128 tokensOwed0 =
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside0X128 - _self.feeGrowthInside0LastX128,
                    _self.liquidity,
                    FixedPoint128.Q128
                )
            );
        // (feeGrowthInside1X128 - _self.feeGrowthInside1LastX128) * _self.liquidity    
        uint128 tokensOwed1 =
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside1X128 - _self.feeGrowthInside1LastX128,
                    _self.liquidity,
                    FixedPoint128.Q128
                )
            );

        // update the position
        if (liquidityDelta != 0) self.liquidity = liquidityNext;
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;
        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            // overflow is acceptable, have to withdraw before you hit type(uint128).max fees
            self.tokensOwed0 += tokensOwed0;
            self.tokensOwed1 += tokensOwed1;
        }
    }
}
