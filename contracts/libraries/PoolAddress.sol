// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

/// @title Provides functions for deriving a pool address from the factory, tokens, and the fee
library PoolAddress {
    // Updated in v0.5.0
    bytes32 internal constant SPOT_POOL_INIT_CODE_HASH = 0x1196a544f92350a644bc29d98c189f745306103cb82ab80726b593e61f3954e9;//23.8.14
    bytes32 internal constant PERP_POOL_INIT_CODE_HASH = 0x0bc883241824f4d9c3d4e2f604efffecbe9a2c66a7395ff085798125b47a2c54;//23.8.14
    bytes32 internal constant POSN_POOL_INIT_CODE_HASH = 0x46d457861d0dec78ff4affff40d37ff6ebfb3e7aa8d49b1beeedc27a27d8dcea;//23.8.14


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
