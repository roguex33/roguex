// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

/// @title Provides functions for deriving a pool address from the factory, tokens, and the fee
library PoolAddress {
    bytes32 internal constant SPOT_POOL_INIT_CODE_HASH = 0x7eb89ab17cc883d055f470bc0250135af3f951b6403ea74f651bcba0136f210b;
    bytes32 internal constant PERP_POOL_INIT_CODE_HASH = 0x2c6f38c87e29af9884df7c0bee701b03461065fcd6924e6a5bad756581165700;
    bytes32 internal constant POSN_POOL_INIT_CODE_HASH = 0x929563b02db566937df22aa2bd9765fdbb240913c7f41e5a7a331a75120e0b23;

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
