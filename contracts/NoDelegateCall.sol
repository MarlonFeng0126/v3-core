// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

/// @title Prevents delegatecall to a contract 阻止委托调用合约
/// @notice Base contract that provides a modifier for preventing delegatecall to methods in a child contract
abstract contract NoDelegateCall {
    /// @dev The original address of this contract 合约原始地址，immutable
    address private immutable original;

    constructor() {
        // Immutables are computed in the init code of the contract, and then inlined into the deployed bytecode.
        // In other words, this variable won't change when it's checked at runtime.
        // lmmutable 状态可以被合约创建时赋予初始值(也就是说只能在构造函数内部初始化)，在合约创建完，成后该数据将永远无法更改(包括合约内部和外部).
        // 与 constant 不同的是,lmmutable 状态变量会被存储到区块链状态中,并且只能被初始化一次
        original = address(this);
    }

    /// @dev Private method is used instead of inlining into modifier because modifiers are copied into each method,
    ///     and the use of immutable means the address bytes are copied in every place the modifier is used.
    // 翻译是，使用private方法而不是内联到修饰符，是因为修饰符被复制到每个方法中，并且使用不可变意味着地址字节在使用修饰符的每个地方都被复制。
    function checkNotDelegateCall() private view {
        require(address(this) == original);
    }

    /// @notice Prevents delegatecall into the modified method
    // 判断当前上下文调用的地址是否是此合约地址original，如果使用delegateCall，那么address(this)就不是此合约地址original
    modifier noDelegateCall() {
        checkNotDelegateCall();
        _;
    }
}
