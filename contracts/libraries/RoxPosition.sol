// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import '../libraries/LiquidityMath.sol';
import '../libraries/SqrtPriceMath.sol';
import '../libraries/TickMath.sol';
import '../libraries/TradeMath.sol';
import '../libraries/PriceRange.sol';
import "../libraries/PositionKey.sol";
import "./FullMath.sol";
import '../interfaces/IRoxPerpPool.sol';

library RoxPosition {
    using SafeMath for uint256;

    uint256 public constant ltprec = 1e12;

    
    // details about the rox position
    struct Position {
        address owner;
        // the tick range of the position
        int24 tickLower;
        int24 tickUpper;

        // the real liquidity of the position
        // supply liquidity = sum(liq / deltaPrice )
        uint128 liquidity;

        // how many uncollected tokens are owed to the position, as of the last computation
        // including 
        uint128 tokensOwed0;
        uint128 tokensOwed1;

        uint128 perpFeeOwed0;
        uint128 perpFeeOwed1;

        uint128 spotFeeOwed0;
        uint128 spotFeeOwed1;

        // uint256 priceMpSt; TODO: do not use array in struct, but save start index
        // uint256 timeMpSt;
        uint256[] priceMap;
        uint256[] timeMap;
    }

    function checkTick(int24 lower, int24 upper) internal pure {
        require(lower % 600 == 0 && upper % 600 == 0, "xTick");
        require(upper > lower, "u<l");
    }

    function getRangeToken(
        uint128 liquidityDelta,
        int24 tickLower,
        int24 tickUpper,
        int24 curTick,
        uint160 sqrtPriceX96
    )internal pure returns (uint256 amount0, uint256 amount1){
        // if (liquidityDelta < 1)
        //     return (0, 0);
        if (curTick < tickLower) {
            // current tick is below the passed range; liquidity can only become in range by crossing from left to
            // right, when we'll need _more_ token0 (sit's becoming more valuable) so user must provide it
            amount0 = SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidityDelta,
                true
            );
        } else if (curTick < tickUpper) {
            // current tick is inside the passed range
            amount0 = SqrtPriceMath.getAmount0Delta(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidityDelta,
                true
            );
            amount1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(tickLower),
                sqrtPriceX96,
                liquidityDelta,
                true
            );
        } else {
            // current tick is above the passed range; liquidity can only become in range by crossing from right to
            // left, when we'll need _more_ token1 (it's becoming more valuable) so user must provide it
            amount1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidityDelta,
                true
            );
        }
    }


    struct UpdCache{
        uint256 entryTimeSlot;
        uint256 curTimeSlot;

        uint256 curPriceSlot;
        uint256 entryPriceSlot;

        uint256 a0cache;
        uint256 a1cache;
        uint128 liquidity;

        uint8 prId;
        uint16 prStart;
        uint16 prEnd;

        int24 tickLower;

        uint32 pPrice;
        uint32 cPrice;
        uint32 entryTime;
        uint32 curTime;
    }




}