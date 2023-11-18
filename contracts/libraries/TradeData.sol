// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

// import "@openzeppelin/contracts/math/SafeMath.sol";
import "./FullMath.sol";

library TradeData {

    uint256 public constant ltprec = 1e12;

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
        int24 tick;
        int24 tickStart;
        int24 tickEnd;
        uint16 prCurrent;
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

    struct LiqCalState {
        uint256 amountSpecifiedRemaining;
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
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
