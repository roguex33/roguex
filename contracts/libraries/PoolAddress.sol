// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

/// @title Provides functions for deriving a pool address from the factory, tokens, and the fee
library PoolAddress {

    bytes32 internal constant SPOT_POOL_INIT_CODE_HASH = 0xbf627bf13ee5e0c664b744e4c008e101521cb670763bf486b40f332a4a38f2a6;//v0.7
    bytes32 internal constant PERP_POOL_INIT_CODE_HASH = 0x9da91232a60f5261cf462c8a5610195aa2d7bdf32c190f07bd30c474c62b7fd2;//v0.7
    bytes32 internal constant POSN_POOL_INIT_CODE_HASH = 0x9e2e4421580ac358a591c60450998c687be4abb6f6974958cefc5694b1c30b9a;//v0.7

    /// @notice The identifying key of the pool
    struct PoolKey {
        address token0;
        address token1;
        uint24 fee;
    }

    /// @notice Returns PoolKey: the ordered tokens with the matched fee levels
    /// @param tokenA The first token of a pool, unsorted
    /// @param tokenB The second token of a pool, unsorted
    /// @param fee The fee level of the pool
    /// @return Poolkey The pool details with ordered token0 and token1 assignments
    function getPoolKey(
        address tokenA,
        address tokenB,
        uint24 fee
    ) internal pure returns (PoolKey memory) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey({token0: tokenA, token1: tokenB, fee: fee});
    }

    /// @notice Deterministically computes the pool address given the factory and PoolKey
    /// @param spotDeployer The spotDeployer address in roguex factory contract
    /// @param key The PoolKey
    /// @return pool The contract address of the spot pool
    function computeAddress(address spotDeployer, PoolKey memory key) internal pure returns (address pool) {
        require(key.token0 < key.token1, "k:0<1");
        pool = address(
            uint256(
                keccak256(
                    abi.encodePacked(
                        hex'ff',
                        spotDeployer,
                        keccak256(abi.encode(key.token0, key.token1, key.fee)),
                        SPOT_POOL_INIT_CODE_HASH
                    )
                )
            )
        );
    }

    function computePerpAddress(address perpDeployer, PoolKey memory key) internal pure returns (address pool) {
        require(key.token0 < key.token1, "k:0<1");
        pool = address(
            uint256(
                keccak256(
                    abi.encodePacked(
                        hex'ff',
                        perpDeployer,
                        keccak256(abi.encode(key.token0, key.token1, key.fee)),
                        PERP_POOL_INIT_CODE_HASH
                    )
                )
            )
        );
    }



}
