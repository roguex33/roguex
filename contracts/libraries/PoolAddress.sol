// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

/// @title Provides functions for deriving a pool address from the factory, tokens, and the fee
library PoolAddress {
    bytes32 internal constant SPOT_POOL_INIT_CODE_HASH = 0xb8085d94e88a9b054bb545f3a69d61c3dbf6c60c341af610ad0f198db6db098b;
    bytes32 internal constant PERP_POOL_INIT_CODE_HASH = 0x746e6db393fe909ce67051aa106b366aa8a9cf9a47827f32171459d77ed493c0;
    bytes32 internal constant POSN_POOL_INIT_CODE_HASH = 0xa70c68e041fff3ce46e1917a40bd428415df131c0ad5a4959fc7ba54daf8b526;

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
        require(key.token0 < key.token1, "sk:0<1");
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

    function perpAddress(address perpDeployer, PoolKey memory key) internal pure returns (address pool) {
        require(key.token0 < key.token1, "pk:0<1");
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

    function posnAddress(address posnDeployer, PoolKey memory key) internal pure returns (address pool) {
        require(key.token0 < key.token1, "nk:0<1");
        pool = address(
            uint256(
                keccak256(
                    abi.encodePacked(
                        hex'ff',
                        posnDeployer,
                        keccak256(abi.encode(key.token0, key.token1, key.fee)),
                        POSN_POOL_INIT_CODE_HASH
                    )
                )
            )
        );
    }

}
