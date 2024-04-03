// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import "./FullMath.sol";

library TradeData {

    uint256 public constant ltprec = 1e12;

    struct RoguFeeSlot{
        uint32 time;
        uint64 fundFeeAccum0;
        uint64 fundFeeAccum1;
        uint32 fundFee0;
        uint32 fundFee1;
        uint24 spotFee;
    }



    struct TradePosition {
        address account;
        uint64 entryFdAccum;

        uint160 entrySqrtPriceX96;
        bool long0;
        uint16 entryPos;
        uint32 openSpread;
        uint32 openTime;
        
        uint256 size;
        uint256 collateral;

        // uint128 sizeLiquidity;
        // uint128 liqResv;

        uint128 reserve;

        uint128 uncollectFee;
        uint128 transferIn;

        uint256 entryIn0;  //sum
        uint256 entryIn1;  //sum

        // Liquidity record part
        // uint128 colLiquidity;
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


    // struct LiqCalState {
    //     uint256 amountSpecifiedRemaining;
    //     uint160 sqrtPriceX96;
    //     int24 tick;
    //     uint128 liquidity;
    // }
}
