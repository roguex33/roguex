// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

/// @title Math library for liquidity
library LiquidityMath {
    /// @notice Add a signed liquidity delta to liquidity and revert if it overflows or underflows
    /// @param x The liquidity before change
    /// @param y The delta by which liquidity should be changed
    /// @return z The liquidity delta
    function addDelta(uint128 x, int128 y) internal pure returns (uint128 z) {
        if (y < 0) {
            //require((z = x > uint128(-y) ? x - uint128(-y) : 0) <= x, 'LS');
            require((z = x - uint128(-y)) <= x, 'LS');
        } else {
            require((z = x + uint128(y)) >= x, 'LA');
        }
    }


    function addDeltaInt(int128 x, int128 y) internal pure returns (int128 z) {
        if (y < 0) {
            require((z = x + y) < x, 'LiS');
        }
        else{
            require((z = x + y) >= x, 'LiA');
        }  
    }
}
