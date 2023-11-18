// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import "../interfaces/IRoguexFactory.sol";
import "../interfaces/IRoxSpotPool.sol";

import "./PeripheryImmutableState.sol";
import "../interfaces/IPoolInitializer.sol";

interface IVoter {
    function createGauge(address _pool) external returns (address);
}

/// @title Creates and initializes spot pools
abstract contract PoolInitializer is IPoolInitializer, PeripheryImmutableState {
    address voter;

    /// @inheritdoc IPoolInitializer
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable override returns (address pool) {
        require(token0 < token1);
        pool = IRoguexFactory(factory).getPool(token0, token1, fee);

        if (pool == address(0)) {
            (pool, , ) = IRoguexFactory(factory).createPool(token0, token1, fee);
            IRoxSpotPool(pool).initialize(sqrtPriceX96);

            if (voter != address(0)) {
                IVoter(voter).createGauge(pool);
            }
        } else {
            (uint160 sqrtPriceX96Existing, , , , , , ) = IRoxSpotPool(pool)
                .slot0();
            if (sqrtPriceX96Existing == 0) {
                IRoxSpotPool(pool).initialize(sqrtPriceX96);
            }
        }
    }
}