// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3Factory.sol';

import './UniswapV3PoolDeployer.sol';
import './NoDelegateCall.sol';

import './UniswapV3Pool.sol';

/// @title Canonical Uniswap V3 factory
/// @notice Deploys Uniswap V3 pools and manages ownership and control over pool protocol fees
/// 部署Uniswap V3 pools，管理池协议费用fee的所有权和控制权
contract UniswapV3Factory is IUniswapV3Factory, UniswapV3PoolDeployer, NoDelegateCall {
    /// @inheritdoc IUniswapV3Factory
    address public override owner;

    /// @inheritdoc IUniswapV3Factory
    mapping(uint24 => int24) public override feeAmountTickSpacing;
    /// @inheritdoc IUniswapV3Factory
    mapping(address => mapping(address => mapping(uint24 => address))) public override getPool;

    constructor() {
        owner = msg.sender;
        emit OwnerChanged(address(0), msg.sender);

        /// 初始化费用fee和TickSpacing的关系
        /// tickSpacing 越小，则说明可设置的价格区间精度越高，但可能会使得每次交易时损耗的 gas 也越高，因为每次交易穿越一个初始化的 tick 时，都会给交易者带来 gas 消耗。
        feeAmountTickSpacing[500] = 10;    // fee:500代表的0.05%    TickSpacing:10
        emit FeeAmountEnabled(500, 10);
        feeAmountTickSpacing[3000] = 60;   // fee:3000代表的0.3%    TickSpacing:60
        emit FeeAmountEnabled(3000, 60);
        feeAmountTickSpacing[10000] = 200; // fee:10000代表的1%    TickSpacing:200
        emit FeeAmountEnabled(10000, 200);
    }

    /// @inheritdoc IUniswapV3Factory
    /// 创建pool，external代表只能被外部调用，noDelegateCall代表不能被delegateCall委托调用
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external override noDelegateCall returns (address pool) {
        require(tokenA != tokenB); // 两个token的地址不能相同
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA); // 给两个地址排序，小的赋值token0，大的赋值token1
        require(token0 != address(0)); // 小的token地址不能为0
        int24 tickSpacing = feeAmountTickSpacing[fee]; // 根据fee获取定义好的tickSpacing
        require(tickSpacing != 0); 
        require(getPool[token0][token1][fee] == address(0)); // 根据token0，token1，fee获取的pool的地址要为0，才能说明pool还没创建
        pool = deploy(address(this), token0, token1, fee, tickSpacing); // 部署pool，deploy方法是在UniswapV3PoolDeployer中定义
        getPool[token0][token1][fee] = pool;
        // populate mapping in the reverse direction, deliberate choice to avoid the cost of comparing addresses
        getPool[token1][token0][fee] = pool;
        emit PoolCreated(token0, token1, fee, tickSpacing, pool);
    }

    /// @inheritdoc IUniswapV3Factory
    function setOwner(address _owner) external override {
        require(msg.sender == owner);
        emit OwnerChanged(owner, _owner);
        owner = _owner;
    }

    /// @inheritdoc IUniswapV3Factory
    function enableFeeAmount(uint24 fee, int24 tickSpacing) public override {
        require(msg.sender == owner);
        require(fee < 1000000);  // 费率小于100%
        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        require(tickSpacing > 0 && tickSpacing < 16384);
        require(feeAmountTickSpacing[fee] == 0);

        feeAmountTickSpacing[fee] = tickSpacing;
        emit FeeAmountEnabled(fee, tickSpacing);
    }
}
