// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title An interface for a contract that is capable of deploying Uniswap V3 Pools
/// 一个能够部署Uniswap V3 Pools的合约接口
/// @notice A contract that constructs a pool must implement this to pass arguments to the pool
/// 构造池的合约必须实现这一点，以便向池传递参数，换句话说创建pool要由合约来构造
/// @dev This is used to avoid having constructor arguments in the pool contract, which results in the init code hash
/// of the pool being constant allowing the CREATE2 address of the pool to be cheaply computed on-chain
/// 这是为了避免在pool池合约中有构造器参数，因为构造函数参数会导致pool池的初始化代码哈希保持不变，从而允许在链上便宜地计算池的CREATE2地址
interface IUniswapV3PoolDeployer {
    /// @notice Get the parameters to be used in constructing the pool, set transiently during pool creation.
    /// 获取用于构造池的参数，在池创建过程中临时设置
    /// @dev Called by the pool constructor to fetch the parameters of the pool
    /// 通过池构造函数调用，以获取池的参数
    /// Returns factory The factory address
    /// 返回工厂合约地址
    /// Returns token0 The first token of the pool by address sort order
    /// 返回token0地址
    /// Returns token1 The second token of the pool by address sort order
    /// 返回token1地址
    /// Returns fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// 返回费用，池中每次swap交换所收取的费用，以bip的百分之一计算
    /// Returns tickSpacing The minimum number of ticks between initialized ticks
    /// 返回tickSpacing，在初始化ticks之间的最小数量，换句话说两个初始化的tick之间最少相隔几个tick
    /// 当添加流动性时，虽然UI交互上选择的是一个价格区间，但实际调用合约时，传入的参数其实是一个 tick 区间。而如果低价或/和高价的 tick 还没有被已存在的头寸用作边界点时，该 tick 将被初始化。tickSpacing 就是用来限制哪些 tick 可以被初始化的。只有那些序号能够被 tickSpacing 整除的 tick 才能被初始化。当 tickSpacing=10 的时候，则只有可以被 10 整除的 tick(, -30,-20,-10,0,10,20,30,.)才可以被初始化;当tickSpacing=200 时，则只有可以被 200整除的 tick(-600,-400,-200,0,200,400600,..)才可被初始化。tickSpacing 越小，则说明可设置的价格区间精度越高，但可能会使得每次交易时损耗的 gas 也越高，因为每次交易穿越一个初始化的 tick 时，都会给交易者带来 gas 消耗。
    function parameters()
        external
        view
        returns (
            address factory,
            address token0,
            address token1,
            uint24 fee,
            int24 tickSpacing
        );
}
