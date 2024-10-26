// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import './BitMath.sol';

/// @title Packed tick initialized state library
/// @notice Stores a packed mapping of tick index to its initialized state
/// 存储tick索引到其初始化状态的打包映射
/// @dev The mapping uses int16 for keys since ticks are represented as int24 and there are 256 (2^8) values per word.
/// 映射使用int16作为键，因为ticks被表示为int24，每个单词有256（2^8）个值。
library TickBitmap {
    /// @notice Computes the position in the mapping where the initialized bit for a tick lives
    /// 计算一个tick的初始化位在映射中的位置
    /// @param tick The tick for which to compute the position
    /// 这里的tick参数传进来的是compressed = tick / tickSpacing
    /// @return wordPos The key in the mapping containing the word in which the bit is stored
    /// @return bitPos The bit position in the word where the flag is stored
    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        // tick的二进制右移8位，每移一次相当于除以2，右移8次相当于除以2^8(256)
        // tick >> 8 ---> tick / 256
        // tick用int24来存储，右移8位，取高16位来作为TickBitmap的key
        wordPos = int16(tick >> 8);
        // bitPos就是tick除以256后的余数
        // 剩下的低8位是2^8一共256个数。也就是说tickBitmap每一条key对应的记录需要管理256个tick状态，最高效的方法就是使用位图，把256个数转换成256个二进制数表示，也就是uint256，相应的位上为1代表当前的tick被引用。
        bitPos = uint8(tick % 256);
    }

    /// @notice Flips the initialized state for a given tick from false to true, or vice versa
    /// 将给定tick的初始化状态从false反转为true，反之亦然
    /// @param self The mapping in which to flip the tick
    /// @param tick The tick to flip
    /// @param tickSpacing The spacing between usable ticks
    function flipTick(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing
    ) internal {
        require(tick % tickSpacing == 0); // ensure that the tick is spaced 确保tick是tickSpacing上的间隔
        (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing);
        // 1的二进制左移bitPos位，右侧补0，相当于1*(2^bitPot)
        // 这步的意思是定位当前tick在wordPos所对应
        uint256 mask = 1 << bitPos;
        // 异或，两个数的二进制按位对比，相同位取0，不同位取1
        // 这步的意思就是翻转bitPos二进制上的0或1，
        self[wordPos] ^= mask;

        // 假设tick = 50，tickSpacing = 10，tick / tickSpacing = 5，根据上面position的计算
        // wordPos = 5 >> 8 = 0
        // bitPos = 5 % 256 = 5
        // mask = 1 << 5 = 32(二进制为100000)
    }

    /// @notice Returns the next initialized tick contained in the same word (or adjacent word) as the tick that is either
    /// to the left (less than or equal to) or right (greater than) of the given tick
    /// 返回下一个初始化的tick，该tick包含在与给定tick左边（小于等于）或右边（大于）的同一word（或相邻word）中
    /// @param self The mapping in which to compute the next initialized tick
    /// @param tick The starting tick
    /// @param tickSpacing The spacing between usable ticks
    /// @param lte Whether to search for the next initialized tick to the left (less than or equal to the starting tick)
    /// lte,是否搜索左侧的下一个初始化tick（小于或等于起始tick）,搜索左侧为ture，搜索右侧为false
    /// @return next The next initialized or uninitialized tick up to 256 ticks away from the current tick
    /// 距离当前tick最多256个tick的下一个初始化或未初始化tick
    /// @return initialized Whether the next tick is initialized, as the function only searches within up to 256 ticks
    /// 下一个tick是否初始化，因为该函数最多只搜索256个刻度
    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        int24 compressed = tick / tickSpacing;
        // 有个疑问，tick必然为tickSpacing的整数倍，为啥余数能不为0？
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity 趋于负无穷

        if (lte) {
            // lte为ture，搜索左侧的下一个初始化tick（小于或等于起始tick）
            (int16 wordPos, uint8 bitPos) = position(compressed);
            // all the 1s at or to the right of the current bitPos
            // 假设tick = 50，tickSpacing = 10，根据position计算，wordPos = 0，bitPos = 5
            // 1 << bitPos = 1 << 5 = 32(100000)
            // mask = 32 - 1 + 32 = 63(111111)
            // 这步的目的是将bitPos的二进制右边全部填充1
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            uint256 masked = self[wordPos] & mask;

            // if there are no initialized ticks to the right of or at the current tick, return rightmost in the word
            // 如果在当前tick的右侧或在当前tick处没有初始化的tick，则返回word的最右侧

            // 如果masked为0，说明bitPos的二进制右边都是0，说明没有一个小于或等于起始的tick被初始化
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
            // 溢出/下溢是可能的，但通过限制tickSpacing和tick从外部防止

            // 假设 initialized 为 true，tick = 50，tickSpacing = 10，compressed = 5，wordPos = 0，bitPos = 5，计算出mask = 63(二进制111111)
            // 假设原先self[wordPos] = 4（二进制为0……0100）, 则masked = self[wordPos] & mask = 4（0……0100），那么BitMath.mostSignificantBit(masked) = 2
            // (compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing = (5 - (5 - 2)) * 10 = 20
            // 计算结果左侧下一个初始化的tick为20，上面假设了self[wordPos] = 4（二进制为0……0100），这个假设刚好是仅初始化了序号20的tick，符合预期

            // 假设 initialized 为 false，tick = 50，tickSpacing = 10，compressed = 5，wordPos = 0，bitPos = 5，计算出mask = 63(二进制111111)
            // 因为未初始化，所以 masked = 0，self[wordPos] = 0
            // (compressed - int24(bitPos)) * tickSpacing = (5 - 5) * 10 = 0
            // 计算结果左侧下一个初始化的tick为0，符合预期
            next = initialized
                ? (compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing
                : (compressed - int24(bitPos)) * tickSpacing;
        } else {
            // lte为false，搜索右侧的下一个初始化tick
            // start from the word of the next tick, since the current tick state doesn't matter
            // 假设tick = 50，tickSpacing = 10，compressed = 5, compressed + 1 = 6, 根据position计算，wordPos = 0，bitPos = 6
            (int16 wordPos, uint8 bitPos) = position(compressed + 1);
            // all the 1s at or to the left of the bitPos
            // ~(按位取反，包括符号位)
            // mask = ~((1 << 6) - 1) = ~(64 - 1) = 11……11000000
            uint256 mask = ~((1 << bitPos) - 1);
            uint256 masked = self[wordPos] & mask;

            // if there are no initialized ticks to the left of the current tick, return leftmost in the word
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
            next = initialized
                ? (compressed + 1 + int24(BitMath.leastSignificantBit(masked) - bitPos)) * tickSpacing
                : (compressed + 1 + int24(type(uint8).max - bitPos)) * tickSpacing;
        }
    }
}
