// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3Pool.sol';

import './NoDelegateCall.sol';

import './libraries/LowGasSafeMath.sol';
import './libraries/SafeCast.sol';
import './libraries/Tick.sol';
import './libraries/TickBitmap.sol';
import './libraries/Position.sol';
import './libraries/Oracle.sol';

import './libraries/FullMath.sol';
import './libraries/FixedPoint128.sol';
import './libraries/TransferHelper.sol';
import './libraries/TickMath.sol';
import './libraries/LiquidityMath.sol';
import './libraries/SqrtPriceMath.sol';
import './libraries/SwapMath.sol';

import './interfaces/IUniswapV3PoolDeployer.sol';
import './interfaces/IUniswapV3Factory.sol';
import './interfaces/IERC20Minimal.sol';
import './interfaces/callback/IUniswapV3MintCallback.sol';
import './interfaces/callback/IUniswapV3SwapCallback.sol';
import './interfaces/callback/IUniswapV3FlashCallback.sol';

contract UniswapV3Pool is IUniswapV3Pool, NoDelegateCall {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];

    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override factory;
    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override token0;
    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override token1;
    /// @inheritdoc IUniswapV3PoolImmutables
    uint24 public immutable override fee;

    /// @inheritdoc IUniswapV3PoolImmutables
    int24 public immutable override tickSpacing;

    /// @inheritdoc IUniswapV3PoolImmutables
    uint128 public immutable override maxLiquidityPerTick; // 表示每个 tick 能接受的最大流动性，是在构造函数中根据 tickSpacing 计算出来的。

    struct Slot0 {
        // the current price
        // 当前价格，记录的是根号价格，且做了扩展，准确来说:sqrtPriceX96=(token1数量/token0数量)^0.5*2^96。
        // 换句话说，这个值代表的是 token0 和 token1 数量比例的平方根，经过放大获得更高的精度
        // 这样设计的目的是为了方便和优化合约中的一些计算。如果想从 sqrtPriceX96 得出具体的价格，还需要做一些额外的计算。
        uint160 sqrtPriceX96;
        // the current tick
        // 当前价格对应的价格点
        int24 tick;
        // the most-recently updated index of the observations array
        // observations数组最新一条记录的索引值
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        // 记录observations数组中实际存储的数量
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        // 下一个要存储的最大observations数量，即将要扩展到的容量值，在observations.write中触发，(表示 observations 即将要扩展到的容量值)
        // 虽然 observations 最大容量为 65535，但实际存储的容量并不会这么大，这是由observationCardinality 所决定的。默认情况下，observationCardinality为1，即observations 实际容量只有 1，一直都只更新第一个元素，此时是无法适用于计算 TWAP的，需要对其进行扩容。
        uint16 observationCardinalityNext;

        // observationIndex,observationCardinality,observationCardinalityNext是跟observations数组有关，是计算预言机价格时需要的

        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        // 当前协议费用占提取时swap手续费的百分比，表示为整数分母(1/x)% ，初始化时为 0，可通过 setFeeProtocol 函数来重置该值
        uint8 feeProtocol;
        // whether the pool is locked
        // 池子是否被锁定
        // unlocked 记录池子的锁定状态，初始化时为 true，主要作为一个防止重入锁来使用。
        bool unlocked;
    }
    /// @inheritdoc IUniswapV3PoolState
    Slot0 public override slot0;

    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal0X128;  // 表示 token0 所累计的手续费总额，使用 Q128.128 浮点数来记录
    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal1X128;  // 表示 token1 所累计的手续费总额，使用 Q128.128 浮点数来记录

    // accumulated protocol fees in token0/token1 units
    // 记录了两个 token 的累计未被领取的协议手续费
    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }
    /// @inheritdoc IUniswapV3PoolState
    ProtocolFees public override protocolFees;

    /// @inheritdoc IUniswapV3PoolState
    uint128 public override liquidity;  // liquidity 记录了池子当前可用的流动性。注意，这里不是指注入池子里的所有流动性总量，而是包含了当前价格的那些头寸的流动性总量。

    /// @inheritdoc IUniswapV3PoolState
    mapping(int24 => Tick.Info) public override ticks; // ticks 记录池子里每个 tick 的详细信息，key为 tick的序号，value 就是详细信息
    /// @inheritdoc IUniswapV3PoolState
    mapping(int16 => uint256) public override tickBitmap; // tickBitmap 记录已初始化的 tick 的位图。如果一个 tick 没有被用作流动性区间的边界点即该 tick 没有被初始化，那在交易过程中可以跳过这个 tick。而为了更高效地寻找下一个已初始化的 tick，就使用了 tickBitmap 来记录已初始化的 tick。如果 tick 已被初始化，位图中对应于该 tick 序号的位置设置为 1，否则为 0。
    /// @inheritdoc IUniswapV3PoolState
    mapping(bytes32 => Position.Info) public override positions; // positions 记录每个头寸的详细信息
    /// @inheritdoc IUniswapV3PoolState
    Oracle.Observation[65535] public override observations; // observations 则是存储了计算预言机价格相关的累加值，包括 tick 累加值和流动性累加值

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
    /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
    modifier lock() {
        require(slot0.unlocked, 'LOK');
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    /// @dev Prevents calling a function from anyone except the address returned by IUniswapV3Factory#owner()
    modifier onlyFactoryOwner() {
        require(msg.sender == IUniswapV3Factory(factory).owner());
        _;
    }

    constructor() {
        int24 _tickSpacing;
        (factory, token0, token1, fee, _tickSpacing) = IUniswapV3PoolDeployer(msg.sender).parameters();
        tickSpacing = _tickSpacing;

        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);  // 获取每个tick的最大流动性
    }

    /// @dev Common checks for valid tick inputs.
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, 'TLU');
        require(tickLower >= TickMath.MIN_TICK, 'TLM');
        require(tickUpper <= TickMath.MAX_TICK, 'TUM');
    }

    /// @dev Returns the block timestamp truncated to 32 bits, i.e. mod 2**32. This method is overridden in tests.
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    /// @dev Get the pool's balance of token0
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// 此函数经过gas优化，以避免除了returndatasize之外的多余的extcodesize检查
    /// staticcall函数，可以让一个合约调用另一个合约时，不修改其状态变量
    /// check
    function balance0() private view returns (uint256) {
        (bool success, bytes memory data) =
            token0.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @dev Get the pool's balance of token1
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) =
            token1.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
        external
        view
        override
        noDelegateCall
        returns (
            int56 tickCumulativeInside,
            uint160 secondsPerLiquidityInsideX128,
            uint32 secondsInside
        )
    {
        checkTicks(tickLower, tickUpper);

        int56 tickCumulativeLower;
        int56 tickCumulativeUpper;
        uint160 secondsPerLiquidityOutsideLowerX128;
        uint160 secondsPerLiquidityOutsideUpperX128;
        uint32 secondsOutsideLower;
        uint32 secondsOutsideUpper;

        {
            Tick.Info storage lower = ticks[tickLower];
            Tick.Info storage upper = ticks[tickUpper];
            bool initializedLower;
            (tickCumulativeLower, secondsPerLiquidityOutsideLowerX128, secondsOutsideLower, initializedLower) = (
                lower.tickCumulativeOutside,
                lower.secondsPerLiquidityOutsideX128,
                lower.secondsOutside,
                lower.initialized
            );
            require(initializedLower);

            bool initializedUpper;
            (tickCumulativeUpper, secondsPerLiquidityOutsideUpperX128, secondsOutsideUpper, initializedUpper) = (
                upper.tickCumulativeOutside,
                upper.secondsPerLiquidityOutsideX128,
                upper.secondsOutside,
                upper.initialized
            );
            require(initializedUpper);
        }

        Slot0 memory _slot0 = slot0;

        if (_slot0.tick < tickLower) {
            return (
                tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityOutsideLowerX128 - secondsPerLiquidityOutsideUpperX128,
                secondsOutsideLower - secondsOutsideUpper
            );
        } else if (_slot0.tick < tickUpper) {
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle(
                    time,
                    0,
                    _slot0.tick,
                    _slot0.observationIndex,
                    liquidity,
                    _slot0.observationCardinality
                );
            return (
                tickCumulative - tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityCumulativeX128 -
                    secondsPerLiquidityOutsideLowerX128 -
                    secondsPerLiquidityOutsideUpperX128,
                time - secondsOutsideLower - secondsOutsideUpper
            );
        } else {
            return (
                tickCumulativeUpper - tickCumulativeLower,
                secondsPerLiquidityOutsideUpperX128 - secondsPerLiquidityOutsideLowerX128,
                secondsOutsideUpper - secondsOutsideLower
            );
        }
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    /// 查询指定时间段内的tick累计值
    /// 该函数指定的参数 secondsAgos 是一个数组，数组的每个元素可以指定离当前时间之前的秒数。
    /// 比如我们想要获取最近1小时的 TWAP，那可传入数组[3600,0]，会查询两个时间点的累计值，3600 表示查询1小时前的累计值，0则表示当前时间的累计值。
    /// 返回的 tickCumulatives 就是对应于入参数组的每个时间点的 tick 累计值
    /// 得到了这两个时间点的 tickCumulatives 之后，就可以算出平均加权的 tick 了。以1小时的时间间隔为例，计算平均加权的 tick 公式为:
    /// averageTick = (tickCumulative[1] - tickCumulative[0]) / 3600
    /// tickCumulative[1] 为当前时间的 tick 累计值，tickCumulative[0]则为1小时前的 tick 累计值。
    /// 最后计算价格，sqrtPriceX96 = TickMath.getSqrtRatioAtTick(averageTick)
    function observe(uint32[] calldata secondsAgos)
        external
        view
        override
        noDelegateCall
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return
            observations.observe(
                _blockTimestamp(),
                secondsAgos,
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );
    }

    /// @inheritdoc IUniswapV3PoolActions
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext)
        external
        override
        lock
        noDelegateCall
    {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // for the event
        uint16 observationCardinalityNextNew =
            observations.grow(observationCardinalityNextOld, observationCardinalityNext);
        slot0.observationCardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev not locked because it initializes unlocked
    function initialize(uint160 sqrtPriceX96) external override {
        require(slot0.sqrtPriceX96 == 0, 'AI');

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96); // 根据sqrtPriceX96价格计算出最大的tick值

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp()); // 默认是1,1

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            feeProtocol: 0,
            unlocked: true
        });

        emit Initialize(sqrtPriceX96, tick);
    }

    struct ModifyPositionParams {
        // the address that owns the position
        address owner;
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        int128 liquidityDelta;
    }

    /// @dev Effect some changes to a position 对position进行一些改变
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return position a storage pointer referencing the position with the given owner and tick range
    /// @return amount0 the amount of token0 owed to the pool, negative if the pool should pay the recipient
    /// @return amount1 the amount of token1 owed to the pool, negative if the pool should pay the recipient
    function _modifyPosition(ModifyPositionParams memory params)
        private
        noDelegateCall
        returns (
            Position.Info storage position,
            int256 amount0,
            int256 amount1
        )
    {
        checkTicks(params.tickLower, params.tickUpper); // 检查tick的范围

        Slot0 memory _slot0 = slot0; // SLOAD for gas optimization

        // 更新头寸
        position = _updatePosition(
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            _slot0.tick
        );

        if (params.liquidityDelta != 0) {
            // 以下价格计算是P=token1/token0，即token1是纵坐标，token0是横坐标坐标
            if (_slot0.tick < params.tickLower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ token0 (it's becoming more valuable) so user must provide it
                // 当前报价低于传递的范围;流动性只能通过从左到右交叉而进入范围内，需要提供更多token0(因为价格如果要穿过区间，只需要消耗token0)
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (_slot0.tick < params.tickUpper) {
                // current tick is inside the passed range
                // 当前报价在传递的范围内
                uint128 liquidityBefore = liquidity; // SLOAD for gas optimization

                // write an oracle entry
                (slot0.observationIndex, slot0.observationCardinality) = observations.write(
                    _slot0.observationIndex,
                    _blockTimestamp(),
                    _slot0.tick,
                    liquidityBefore,
                    _slot0.observationCardinality,
                    _slot0.observationCardinalityNext
                );

                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    _slot0.sqrtPriceX96,
                    params.liquidityDelta
                );

                liquidity = LiquidityMath.addDelta(liquidityBefore, params.liquidityDelta);
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ token1 (it's becoming more valuable) so user must provide it
                // 当前报价高于传递的范围;流动性只能通过从右到左交叉而进入范围内，需要提供更多token1(因为价格如果要穿过区间，只需要消耗token1)
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    /// @dev Gets and updates a position with the given liquidity delta
    /// 获取并更新具有给定流动性增量的头寸
    /// @param owner the owner of the position
    /// @param tickLower the lower tick of the position's tick range
    /// @param tickUpper the upper tick of the position's tick range
    /// @param tick the current tick, passed to avoid sloads
    function _updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private returns (Position.Info storage position) {
        position = positions.get(owner, tickLower, tickUpper); // owner, tickLower, tickUpper唯一定位头寸

        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128; // SLOAD for gas optimization
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128; // SLOAD for gas optimization

        // if we need to update the ticks, do it
        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle(
                    time,
                    0,
                    slot0.tick,
                    slot0.observationIndex,
                    liquidity,
                    slot0.observationCardinality
                );

            // 更新一个tick，如果tick从初始化翻转到未初始化，或者从未初始化翻转到初始化，则返回true，如果更新前后都是初始化或者都是未初始化，则为false
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                false,
                maxLiquidityPerTick
            );
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true,
                maxLiquidityPerTick
            );

            // 将给定tick的初始化状态从false反转为true，或者从true反转为false
            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        // 计算费用增长数据
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);

        // 将累积的费用记入用户的头寸
        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        // clear any tick data that is no longer needed
        // 如果是减少流动性的情况，可能导致tick由初始化翻转为未初始化，则清除tick数据
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// 添加流动性
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    /// noDelegateCall通过_modifyPosition间接应用
    /// @param recipient The address for which the liquidity will be created  创建流动性的地址，流动性接收者，通常是NonfungiblePositionManager合约地址
    /// @param tickLower The lower tick of the position in which to add liquidity 添加流动性的头寸tick下限，即区间价格下限的 tick 序号
    /// @param tickUpper The upper tick of the position in which to add liquidity 添加流动性的头寸tick上限，即区间价格上限的 tick 序号
    /// @param amount The amount of liquidity to mint 铸造的流动性数量
    /// @param data Any data that should be passed through to the callback 传给回调函数的数据
    /// @return amount0 The amount of token0 that was paid to mint the given amount of liquidity. Matches the value in the callback token0的数量，被用来支付铸造给定数量的流动性
    /// @return amount1 The amount of token1 that was paid to mint the given amount of liquidity. Matches the value in the callback token1的数量，被用来支付铸造给定数量的流动性
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        require(amount > 0);
        // 添加流动性主要操作是在_modifyPosition函数里，执行完该函数返回需要添加到池子里的两种 token 的具体数额 amount0 和 amount1
        (, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: recipient,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(amount).toInt128()
                })
            );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();

        // 调用 msg.sender 的回调函数uniswapV3MintCallback，在回调函数中需要完成两种 token 的支付。
        // msg.sender 一般是NonfungiblePositionManager 合约，所以NonfungiblePositionManager合约会实现该回调函数来完成支付。
        // 执行完回调函数之后，那池子里两种 token 的余额就会发生变化判断其前后余额即可，
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        if (amount0 > 0) require(balance0Before.add(amount0) <= balance0(), 'M0');
        if (amount1 > 0) require(balance1Before.add(amount1) <= balance1(), 'M1');

        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// 提取收益
    /// @param recipient The address which should receive the fees collected  接收提取费用的地址
    /// @param tickLower The lower tick of the position for which to collect fees 要提取费用的头寸的tick下限
    /// @param tickUpper The upper tick of the position for which to collect fees 要提取费用的头寸的tick上限
    /// @param amount0Requested How much token0 should be withdrawn from the fees owed  从所欠费用中提取多少token0
    /// @param amount1Requested How much token1 should be withdrawn from the fees owed  从所欠费用中提取多少token1
    /// @return amount0 The amount of fees collected in token0 实际提取的token0的数量
    /// @return amount1 The amount of fees collected in token1 实际提取的token1的数量
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        // we don't need to checkTicks here, because invalid positions will never have non-zero tokensOwed{0,1}
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(amount).toInt128()  // 因为是移除流动性，所以转为负数
                })
            );

        amount0 = uint256(-amount0Int); // 返回的amount0Int是负数
        amount1 = uint256(-amount1Int); // 返回的amount1Int是负数

        // 将 amount0 和 amount1 分别累加到了头寸的 tokensOwed0 和 tokensOwed1.
        // UniswapV3 的处理方式并不是移除流动性时直接把两种 token 资产转给用户，而是先累加到 tokensOwed0 和 tokensOwed1，代表这是欠用户的资产，其中也包括该头寸已赚取到的手续费。
        // 之后，用户其实是要通过 collect 函数来提取 tokensOwed0 和tokensOwed1 里的资产
        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
        }

        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    struct SwapCache {
        // the protocol fee for the input token
        // 输入token的协议费用
        uint8 feeProtocol;
        // liquidity at the beginning of the swap
        // 交换开始前的流动性
        uint128 liquidityStart;
        // the timestamp of the current block
        // 当前区块的时间戳
        uint32 blockTimestamp;
        // the current value of the tick accumulator, computed only if we cross an initialized tick
        // tick累加器的当前值，仅在越过初始化的tick时计算
        int56 tickCumulative;
        // the current value of seconds per liquidity accumulator, computed only if we cross an initialized tick
        // 每单位流动性累加器的秒的当前值，仅在越过初始化的tick时计算
        uint160 secondsPerLiquidityCumulativeX128;
        // whether we've computed and cached the above two accumulators
        // 是否计算并缓存了上述两个累加器
        bool computedLatestObservation;
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    // 交换的顶层状态，交换的结果最后记录在存储中
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        // 输入/输出资产中待交换的剩余数量
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        // 已经交换输出/输入资产的数量
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // amount of input token paid as protocol fee
        uint128 protocolFee;
        // the current liquidity in range
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @param recipient The address to receive the output of the swap  
    /// @param zeroForOne The direction of the swap, true for token0 to token1, false for token1 to token0  
    /// 交易方向，true表示用token0换token1，false表示用token1换token0
    /// @param amountSpecified The amount of the swap, which implicitly configures the swap as exact input (positive), or exact output (negative)
    /// 指定的交易数额，如果是正数则为指定的输入，负数则为指定的输出
    /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this
    /// value after the swap. If one for zero, the price cannot be greater than this value after the swap
    /// 限定的价格
    /// 如果 zeroForOne 为 true，那交易后的价格不能小于 sqrtPriceLimitX96;
    /// 如果 zeroForOne 为 false，则交易后的价格不能大于 sqrtPriceLimitX96。
    /// sqrtPriceLimitX96是通过token1/token0为基础去计算的，zeroForOne 为 true，表示用token0换token1，token0数量变多，token1数量变少，token1/token0的值会变小，反之亦然
    /// @param data Any data to be passed through to the callback
    /// @return amount0 The delta of the balance of token0 of the pool, exact when negative, minimum when positive amount0是交易后token0的实际成交数额
    /// @return amount1 The delta of the balance of token1 of the pool, exact when negative, minimum when positive amount1是交易后token1的实际成交数额
    /// 交换
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override noDelegateCall returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, 'AS');

        Slot0 memory slot0Start = slot0; // 将状态变量保存在内存中，后续访问通过 MLOAD 完成，可以节省 gas

        require(slot0Start.unlocked, 'LOK');
        // sqrtPriceLimitX96是通过token1/token0为基础去计算的
        // zeroForOne为true，表示用token0换token1，token0数量变多,token1数量变少,sqrtPriceLimitX96就会变小，所以就应该会小于当前的价格slot0Start.sqrtPriceX96
        // 同时sqrtPriceLimitX96要小于最小刻度的价格TickMath.MIN_SQRT_RATIO,TickMath.MIN_SQRT_RATIO等价于getSqrtRatioAtTick(MIN_TICK)
        // 反之亦然
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            'SPL'
        );

        slot0.unlocked = false; // 防止重入

        // 缓存交易前的数据，以节省gas
        SwapCache memory cache =
            SwapCache({
                liquidityStart: liquidity,
                blockTimestamp: _blockTimestamp(),
                feeProtocol: zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4),
                secondsPerLiquidityCumulativeX128: 0,
                tickCumulative: 0,
                computedLatestObservation: false
            });

        bool exactInput = amountSpecified > 0; // 如果 amountSpecifed 为正数，则指定的是确定的输入数额

        // 缓存交易过程中需要用到的临时变量
        SwapState memory state =
            SwapState({
                amountSpecifiedRemaining: amountSpecified,
                amountCalculated: 0,
                sqrtPriceX96: slot0Start.sqrtPriceX96,
                tick: slot0Start.tick,
                feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
                protocolFee: 0,
                liquidity: cache.liquidityStart
            });

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        // 只要我们没有使用全部输入/输出并且没有达到价格限制，就继续交换
        // 换句话说，当剩余可交易金额为零，或交易后价格达到了限定的价格之后才退出循环
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            // 缓存每一次循环的状态变量
            StepComputations memory step;
            // 交易的起始价格
            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            // 通过tick位图找到下一位已初始化的tick，即下一个流动性边界点
            // zeroForOne为是否搜索左侧的下一个初始化tick（小于或等于起始tick）,搜索左侧为ture，搜索右侧为false
            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                tickSpacing,
                zeroForOne
            );

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            // 确保我们没有超过最小/最大刻度，因为刻度位图不知道这些界限
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            // 获取下一个tick的价格
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            // 计算值以交换到目标点、价格限制或输入/输出量耗尽的点
            // 在当前价格和下一个价格之间计算交易结果，返回最新价格、消耗的amountln、输出的amountOut 和手续费fee
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96, // 当前池子中价格
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96, // 目标价格，即不能超过的价格。
                state.liquidity, // 当前价格的流动性
                state.amountSpecifiedRemaining, // 剩余可交易的token数量
                fee //费率
            );

            if (exactInput) {
                // 此时的剩余可交易金额为正数，需减去消耗的输入 amountln 和手续费 feeAmount
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                // 此时该值表示 tokenOut 的累加值，结果为负数
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
            } else {
                // 此时的剩余可交易金额为负数，需加上输出的 amountOut
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                // 已经交换输出/输入资产的数量，此时该值表示 tokenIn 的累加值，结果为正数
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
            }

            // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            // 如果协议费用开启，计算多少所欠，减少feeAmount，增加protocolFee
            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol;
                step.feeAmount -= delta;
                state.protocolFee += uint128(delta);
            }

            // update global fee tracker
            // 更新全局费用跟踪器
            if (state.liquidity > 0)
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);

            // shift tick if we reached the next price
            // 如果达到了下一个价格，则需要移动 tick
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                // 如果 tick 已经初始化，则需要执行 tick 的转换
                if (step.initialized) {
                    // check for the placeholder value, which we replace with the actual value the first time the swap
                    // crosses an initialized tick
                    // 检查占位符的值，我们在交换第一次穿过初始化的tick时用实际值替换它
                    if (!cache.computedLatestObservation) {
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                            cache.blockTimestamp,
                            0,
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true;
                    }
                    // 转换到下一个 tick
                    int128 liquidityNet =
                        ticks.cross(
                            step.tickNext,
                            (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                            (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128),
                            cache.secondsPerLiquidityCumulativeX128,
                            cache.tickCumulative,
                            cache.blockTimestamp
                        );
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    // 如果我们向左移动，我们将liquidityNet解释为相反的符号安全，因为liquidityNet不能是type(int128).min
                    // 即根据交易方向增加/减少相应的流动性
                    if (zeroForOne) liquidityNet = -liquidityNet;
                    // 更新流动性
                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }
                // 更新tick
                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                // 重新计算，除非我们处于较低的tick边界（即已经转换过刻度），并且没有移动
                // 如果不需要移动 tick，则根据最新价格换算成最新的 tick
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // update tick and write an oracle entry if the tick change
        // 更新标记，如果标记改变，写一个oracle条目
        if (state.tick != slot0Start.tick) {
            (uint16 observationIndex, uint16 observationCardinality) =
                observations.write(
                    slot0Start.observationIndex,
                    cache.blockTimestamp,
                    slot0Start.tick,
                    cache.liquidityStart,
                    slot0Start.observationCardinality,
                    slot0Start.observationCardinalityNext
                );
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            // otherwise just update the price
            // 否则只需更新价格
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // update liquidity if it changed
        // 如果改变了更新流动性
        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        // update fee growth global and, if necessary, protocol fees
        // overflow is acceptable, protocol has to withdraw before it hits type(uint128).max fees
        // 更新费用增长是全局的，如果有必要，协议费用溢出是可以接受的，协议必须在达到type(uint128).max之前提取
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
        }

        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        // do the transfers and collect payment
        // 转账和支付
        // 先将 tokenOut 转给了用户，然后执行了回调函数 uniswapV3SwapCallback，在回调函数里会完成 tokenn 的支付，执行完回调函数后的余额校验是为了确保回调函数确实完成了tokenin 的支付。
        // 因为先将 tokenOut 转给了用户，之后才完成支付，因此在回调函数中其实还可以做和 UniswapV2 -样的 flash swap。
        if (zeroForOne) {
            if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');
        } else {
            if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');
        }

        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
        slot0.unlocked = true; // 解除重入锁
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @param recipient The address which will receive the token0 and token1 amounts 接收所贷token的地址
    /// @param amount0 The amount of token0 to send 借贷的token0数量
    /// @param amount1 The amount of token1 to send 借贷的token1数量
    /// @param data Any data to be passed through to the callback 给回调函数的参数
    /// 闪电贷，闪电贷赚取的手续费也是分配给 LP 和协议费
    /// flash 函数实现了闪电贷功能，与 flash swap 不同，闪电贷借什么就需要还什么。另外,UniswapV3 的闪电贷可以两种 token 都借。
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override lock noDelegateCall {
        uint128 _liquidity = liquidity;
        require(_liquidity > 0, 'L');
        // 计算借贷的手续费
        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);
        // 记录还款前的余额
        uint256 balance0Before = balance0();
        uint256 balance1Before = balance1();
        // 将所借token转给用户
        if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);
        // 调用回调函数，在该函数里需要完成还款，包括还所借 token 和支付手续费
        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);
        // 读取还款后的余额
        uint256 balance0After = balance0();
        uint256 balance1After = balance1();
        // 还款后的余额不能小于还款前的余额加上手续费
        require(balance0Before.add(fee0) <= balance0After, 'F0');
        require(balance1Before.add(fee1) <= balance1After, 'F1');

        // sub is safe because we know balanceAfter is gt balanceBefore by at least fee
        // sub是安全的，因为我们知道balanceAfter比balanceBefore至少要安全
        // 计算出实际收到的手续费
        uint256 paid0 = balance0After - balance0Before;
        uint256 paid1 = balance1After - balance1Before;
        // 手续费分配
        if (paid0 > 0) {
            uint8 feeProtocol0 = slot0.feeProtocol % 16;
            uint256 fees0 = feeProtocol0 == 0 ? 0 : paid0 / feeProtocol0;
            if (uint128(fees0) > 0) protocolFees.token0 += uint128(fees0);
            feeGrowthGlobal0X128 += FullMath.mulDiv(paid0 - fees0, FixedPoint128.Q128, _liquidity);
        }
        if (paid1 > 0) {
            uint8 feeProtocol1 = slot0.feeProtocol >> 4;
            uint256 fees1 = feeProtocol1 == 0 ? 0 : paid1 / feeProtocol1;
            if (uint128(fees1) > 0) protocolFees.token1 += uint128(fees1);
            feeGrowthGlobal1X128 += FullMath.mulDiv(paid1 - fees1, FixedPoint128.Q128, _liquidity);
        }

        emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external override lock onlyFactoryOwner {
        require(
            (feeProtocol0 == 0 || (feeProtocol0 >= 4 && feeProtocol0 <= 10)) &&
                (feeProtocol1 == 0 || (feeProtocol1 >= 4 && feeProtocol1 <= 10))
        );
        uint8 feeProtocolOld = slot0.feeProtocol;
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4);
        emit SetFeeProtocol(feeProtocolOld % 16, feeProtocolOld >> 4, feeProtocol0, feeProtocol1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    function collectProtocol(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock onlyFactoryOwner returns (uint128 amount0, uint128 amount1) {
        amount0 = amount0Requested > protocolFees.token0 ? protocolFees.token0 : amount0Requested;
        amount1 = amount1Requested > protocolFees.token1 ? protocolFees.token1 : amount1Requested;

        if (amount0 > 0) {
            if (amount0 == protocolFees.token0) amount0--; // ensure that the slot is not cleared, for gas savings
            protocolFees.token0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            if (amount1 == protocolFees.token1) amount1--; // ensure that the slot is not cleared, for gas savings
            protocolFees.token1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit CollectProtocol(msg.sender, recipient, amount0, amount1);
    }
}
