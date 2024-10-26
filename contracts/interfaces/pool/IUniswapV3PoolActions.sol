// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title Permissionless pool actions
/// @notice Contains pool methods that can be called by anyone
/// 包含任何人都可以调用的池方法，定义了UniswapV3Pool的核心函数
/// initialize 初始化价格
/// mint 添加流动性
/// collect 提取收益
/// burn 移除流动性
/// swap 兑换
/// increaseObservationCardinalityNext 扩展observations数据可存储的容量
interface IUniswapV3PoolActions {
    /// @notice Sets the initial price for the pool  为池设置初始化价格
    /// @dev Price is represented as a sqrt(amountToken1/amountToken0) Q64.96 value
    /// @param sqrtPriceX96 the initial sqrt price of the pool as a Q64.96
    /// initialize 通常会在第一次添加流动性时被调用，主要会初始化 slot0 状态变量，其中sqrtPriceX96 是直接作为入参传入的，因为第一次添加流动性时，价格其实是由LP 自己定的。
    /// 初始的 tick 则是根据 sqrtPriceX96 计算出来的。而最后一个函数increaseObservationCardinalityNext 是用于预言机的，因为默认的 observations 数组实际存储的容量只是 1，需要扩展这个容量才可计算预言机价格。
    function initialize(uint160 sqrtPriceX96) external;

    /// @notice Adds liquidity for the given recipient/tickLower/tickUpper position
    /// 为给定的recipient/tickLower/tickUpper position添加流动性
    /// @dev The caller of this method receives a callback in the form of IUniswapV3MintCallback#uniswapV3MintCallback
    /// in which they must pay any token0 or token1 owed for the liquidity. The amount of token0/token1 due depends
    /// on tickLower, tickUpper, the amount of liquidity, and the current price.
    /// @param recipient The address for which the liquidity will be created  创建流动性的地址，流动性接收者
    /// @param tickLower The lower tick of the position in which to add liquidity 添加流动性的头寸tick下限，即区间价格下限的 tick 序号
    /// @param tickUpper The upper tick of the position in which to add liquidity 添加流动性的头寸tick上限，即区间价格上限的 tick 序号
    /// @param amount The amount of liquidity to mint 铸造的流动性数量
    /// @param data Any data that should be passed through to the callback 传给回调函数的数据
    /// @return amount0 The amount of token0 that was paid to mint the given amount of liquidity. Matches the value in the callback token0的数量，被用来支付铸造给定数量的流动性
    /// @return amount1 The amount of token1 that was paid to mint the given amount of liquidity. Matches the value in the callback token1的数量，被用来支付铸造给定数量的流动性
    /// 添加流动性
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Collects tokens owed to a position 收集某一头寸所欠的token
    /// @dev Does not recompute fees earned, which must be done either via mint or burn of any amount of liquidity.
    /// Collect must be called by the position owner. To withdraw only token0 or only token1, amount0Requested or
    /// amount1Requested may be set to zero. To withdraw all tokens owed, caller may pass any value greater than the
    /// actual tokens owed, e.g. type(uint128).max. Tokens owed may be from accumulated swap fees or burned liquidity.
    /// 不重新计算已赚取的费用，通过mint或burn任何数量的流动性来完成。
    /// Collect函数必须通过头寸owner调用。如果只提取token0获取只提取token1，将amount0Requested或者amount1Requested设置为0。
    /// 如要要提取所有欠的token，调用者可以传递比实际欠的token大的任何值，例如type(uint128).max。
    /// 欠下的token可能来自累积的swap费用或burn流动性。
    /// @param recipient The address which should receive the fees collected  接收提取费用的地址
    /// @param tickLower The lower tick of the position for which to collect fees 要提取费用的头寸的tick下限
    /// @param tickUpper The upper tick of the position for which to collect fees 要提取费用的头寸的tick上限
    /// @param amount0Requested How much token0 should be withdrawn from the fees owed  从所欠费用中提取多少token0
    /// @param amount1Requested How much token1 should be withdrawn from the fees owed  从所欠费用中提取多少token1
    /// @return amount0 The amount of fees collected in token0 实际提取的token0的数量
    /// @return amount1 The amount of fees collected in token1 实际提取的token1的数量
    /// 提取收益，recipient 就是接收 token 的地址，tickLower 和 tickUpper 指定了头寸区间，amount0Requested 和 amount1Requested 是用户希望提取的数额。返回值amount0 和 amount1 就是实际提取的数额。
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);

    /// @notice Burn liquidity from the sender and account tokens owed for the liquidity to the position
    /// @dev Can be used to trigger a recalculation of fees owed to a position by calling with an amount of 0
    /// @dev Fees must be collected separately via a call to #collect
    /// @param tickLower The lower tick of the position for which to burn liquidity
    /// @param tickUpper The upper tick of the position for which to burn liquidity
    /// @param amount How much liquidity to burn
    /// @return amount0 The amount of token0 sent to the recipient
    /// @return amount1 The amount of token1 sent to the recipient
    /// 移除流动性
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Swap token0 for token1, or token1 for token0 用token0换token1或者用token1换token0
    /// @dev The caller of this method receives a callback in the form of IUniswapV3SwapCallback#uniswapV3SwapCallback
    /// @param recipient The address to receive the output of the swap  
    /// @param zeroForOne The direction of the swap, true for token0 to token1, false for token1 to token0  
    /// 交易方向，true表示用token0换token1，false表示用token1换token0
    /// @param amountSpecified The amount of the swap, which implicitly configures the swap as exact input (positive), or exact output (negative)
    /// 指定的交易数额，如果是正数则为指定的输入，负数则为指定的输出
    /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this
    /// value after the swap. If one for zero, the price cannot be greater than this value after the swap
    /// 限定的价格
    /// 如果 zeroForOne 为 true，那交易后的价格不能小于 sqrtPriceLimitX96;
    /// 如果 zeroForOne 为 false，则交易后的价格不能大于 sqrtPriceLimitX96。返回值 amount0 和amount1 是交易后两个 token 的实际成交数额。
    /// sqrtPriceLimitX96是通过token1/token0为基础去计算的，zeroForOne 为 true，表示用token0换token1，token0数量变多，token1数量变少，token1/token0的值会变小，反之亦然
    /// @param data Any data to be passed through to the callback
    /// @return amount0 The delta of the balance of token0 of the pool, exact when negative, minimum when positive amount0是交易后token0的实际成交数额
    /// @return amount1 The delta of the balance of token1 of the pool, exact when negative, minimum when positive amount1是交易后token1的实际成交数额
    /// 兑换
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    /// @notice Receive token0 and/or token1 and pay it back, plus a fee, in the callback
    /// 接收token0和/或token1，并在回调中支付它，外加费用
    /// @dev The caller of this method receives a callback in the form of IUniswapV3FlashCallback#uniswapV3FlashCallback
    /// @dev Can be used to donate underlying tokens pro-rata to currently in-range liquidity providers by calling
    /// with 0 amount{0,1} and sending the donation amount(s) from the callback
    /// @param recipient The address which will receive the token0 and token1 amounts 接收所贷token的地址
    /// @param amount0 The amount of token0 to send 借贷的token0数量
    /// @param amount1 The amount of token1 to send 借贷的token1数量
    /// @param data Any data to be passed through to the callback 给回调函数的参数
    /// 闪电贷，闪电贷赚取的手续费也是分配给 LP 和协议费
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;

    /// @notice Increase the maximum number of price and liquidity observations that this pool will store
    /// @dev This method is no-op if the pool already has an observationCardinalityNext greater than or equal to
    /// the input observationCardinalityNext.
    /// @param observationCardinalityNext The desired minimum number of observations for the pool to store
    /// 扩展observations数据可存储的容量，即对observations数组的扩容，指定的参数就是想要扩容的容量
    /// 而扩容为多少合适呢?这就要看需要使用多长时间的 TWAP 了，还要看是用在 Layer1 还是 Layer2。
    /// 假设 TWAP的时间窗口为1小时，那如果是在 Layer1 的话，因为出块时间平均为 10 几秒，那1小时出块最大上限也不会超过 360，即是说扩容的容量最大也不需要超过 360。
    /// 而如果是用在 Layer2 的话，因为 Layer2 定序器的原因，以 Arbitrum 为例，每隔1分钟才会有一次时间戳的更新，所以理论上，1 小时的 TWAP 只要有 60 的容量就足够，可以增加一点冗余扩容到 70。
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}
