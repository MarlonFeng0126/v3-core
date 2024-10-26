// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3PoolDeployer.sol';

import './UniswapV3Pool.sol';

contract UniswapV3PoolDeployer is IUniswapV3PoolDeployer {
    struct Parameters {
        address factory;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
    }

    /// @inheritdoc IUniswapV3PoolDeployer
    Parameters public override parameters;

    /// @dev Deploys a pool with the given parameters by transiently setting the parameters storage slot and then
    /// clearing it after deploying the pool.
    /// 通过临时设置参数存储槽，然后在部署池后清楚，部署一个给定参数的pool
    /// @param factory The contract address of the Uniswap V3 factory
    /// @param token0 The first token of the pool by address sort order
    /// @param token1 The second token of the pool by address sort order
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @param tickSpacing The spacing between usable ticks
    function deploy(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing
    ) internal returns (address pool) {
        // 给结构体变量赋值
        parameters = Parameters({factory: factory, token0: token0, token1: token1, fee: fee, tickSpacing: tickSpacing});
        // 部署UniswapV3Pool合约创建一个pool
        // 这里部署合约是使用的了create2，create2操作码使我们在智能合约部署在以太坊网络之前就能预测合约的地址，普通的create创建智能合约计算地址是address = hash(创建者地址, nonce)，创建者地址不会变，但nonce可能会随时间而改变，因此用CREATE创建的合约地址不好预测。
        // CREATE2的用法和CREATE类似，同样是new一个合约，并传入新合约构造函数所需的参数，只不过要多传一个salt参数
        // 使用create2   新地址 = hash("0xFF",创建者地址, salt, initcode)     salt（盐）：一个创建者指定的bytes32类型的值，它的主要目的是用来影响新创建的合约的地址。initcode: 新合约的初始字节码（合约的Creation Code和构造函数的参数）。
        pool = address(new UniswapV3Pool{salt: keccak256(abi.encode(token0, token1, fee))}());
        // delete用于释放空间，为鼓励主动对空间的回收，释放空间将会返还一些gas。
        delete parameters;
    }
}
