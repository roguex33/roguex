// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import './LowGasSafeMath.sol';
import './SafeCast.sol';

import './TickMath.sol';
import './LiquidityMath.sol';
import "./FullMath.sol";

library TickRange {
    using LowGasSafeMath for int256;
    using SafeCast for int256;

    // zeroForOne: true for token0 to token1, false for token1 to token0
    function rightBoundaryTick(int24 tick) internal pure returns (int24) {
        return ((tick + 887400) / 600 + 1) * 600 - 887400;
    }
    
    function leftBoundaryTick(int24 tick) internal pure returns (int24) {
        // if at boundary(%600 == 0), check next left b.
        return ((tick + 887399) / 600) * 600 - 887400;
    }

    function leftBoundaryTickWithin(int24 tick) internal pure returns (int24) {
        // if at boundary(%600 == 0), check next left b.
        return ((tick + 887400) / 600) * 600 - 887400;
    }

    function tickToPr(int24 tick) internal pure returns (uint16) {
        // require(tick >= 0);
        tick = (tick + 887400) / 600;
        return uint16(tick);
    }
}
