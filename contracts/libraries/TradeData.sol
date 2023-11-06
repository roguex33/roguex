// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./FullMath.sol";

library TradeData {
    using SafeMath for uint256;

    uint256 public constant ltprec = 1e12;

    struct SettleCache{
        int24 tmpSht;
        int24 tickCur;
        int24 startTickRoundLeft;
        uint24 startPs;
        uint16 startPr;
        uint16 endPs;
        //---128----
        uint16 psId;
        uint16 prId;
        uint32 psTime;
        bool bOdd;
        //-- 
        uint256 prCacheTime;
        uint256 curTime;
        uint256 ltLiq;
        uint256 liqSum;
        uint256 curPriceSlot;
        uint256 tkSum;
        uint256 curPrTimeSlot;
    }

    struct RoguFeeSlot{
        uint32 time;
        uint64 fundFeeAccum0;
        uint64 fundFeeAccum1;
        uint32 fundFee0;
        uint32 fundFee1;
    }



    struct TradePosition {
        address account;

        uint160 entrySqrtPriceX96;
        uint32 positionTime;
        uint64 entryFdAccum;
        
        uint256 size;
        uint256 collateral;
        uint256 reserve;
        uint256 liqResv;

        uint256 uncollectFee;
        uint256 transferIn;

        uint256 entryLiq0;  //sum
        uint256 entryLiq1;  //sum

        // Liquidity record part
        // uint128 colLiquidity;
        uint128 sizeLiquidity;
        uint16 entryPos;
        int32 openSpread;
        bool long0;
        // uint256 feeCollect;
    }
    
    struct PriceRangeLiq {
        int24 tickSpacing;
        int24 tick;
        int24 tickStart;
        int24 tickEnd;
        uint24 fee;
        uint16 prCurrent;
        uint16 prStart; // 2958 max
        uint16 prEnd;
        uint16 curIdx;
    }

    struct SwapState {
        int256 amountSpecifiedRemaining;
        int256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        uint256 feeGrowthGlobalX128;
    }
    struct StepComputations {
        uint160 sqrtPriceStartX96;
        int24 tickNext;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    struct OpenPricState {
        uint160 openPrice;
        int24 openTick;
        int24 curTick;
        uint160 curPrice;
        uint160 sqrtPriceX96;
    }
    
}
