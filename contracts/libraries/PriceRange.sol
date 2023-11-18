// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import './LowGasSafeMath.sol';
import './SafeCast.sol';

import './TickMath.sol';
import './LiquidityMath.sol';
import "./FullMath.sol";
import './FixedPoint128.sol';

import "hardhat/console.sol";

library PriceRange {
    using LowGasSafeMath for int256;
    using SafeCast for int256;

    uint256 constant PRP_PREC =  100000000;
    uint256 constant PRP_MAXP = 4100000000;
    uint256 constant PRP_MINP =        100;
    uint256 constant PS_SPACING = 100000;


    // Price Range:
    //      priceRangeId = (curTick + 887400)/600; 
    //            NameAs => pr /@ max value = 887272 * 2(1774544Ticks) / 600 = 2959 PriceRanges
    // Price Slot:
    //      every 8 price Range(32bitPerId) stored in one uint256 slot,
    //      psId : 0 ~ 369      (2959 / 8 = 370)
    //      price Tick SlotId = priceRangeId / 8; 
    //      update time: u32,
    // Bits used from high to low 
    // uint32 per Price: 
    //      U32 max value : 4,294,967,295 
    //      PricePrecision:   100,000,000
    //      max price lmt : 42x
    // tick to price Range, priceRange is 0 ~ 2958, every 600Tick Per Range,

    function tickTo(int24 tick) internal pure returns (uint16 pr, uint16 ps) {
        pr = uint16((tick + 887400) / 600);
        ps = pr / 8;
    }

    function tickToPr(int24 tick) internal pure returns (uint16) {
        // require(tick >= 0);
        tick = (tick + 887400) / 600;
        return uint16(tick);
    }
    function prToPs(uint256 pr) internal pure returns (uint256) {
        return pr / 8;
    }

    function isRightCross(uint256 pr) internal pure returns (bool) {
        return pr % 8 == 7;
    }

    function isLeftCross(uint256 pr) internal pure returns (bool) {
        return pr % 8 == 0;
    }


    function prStartTick(uint256 pr) internal pure returns (int24) {
        require(pr < 2959, "nPR"); //2958 max range.
        int256 _tk = int256(pr * 600);
        return int24(_tk - 887400);
    }

    // zeroForOne: true for token0 to token1, false for token1 to token0
    function rightBoundaryTick(int24 tick) internal pure returns (int24) {
        return ((tick + 887400) / 600 + 1) * 600 - 887400;
        // return prStartTick(tickToPr(tick) + 1);
    }

    function leftBoundaryTick(int24 tick) internal pure returns (int24) {
        // if at boundary(%600 == 0), check next left b.
        return ((tick + 887399) / 600) * 600 - 887400;
        // return prStartTick(tickToPr(tick - 1));
    }

    function leftBoundaryTickWithin(int24 tick) internal pure returns (int24) {
        // if at boundary(%600 == 0), check next left b.
        return ((tick + 887400) / 600) * 600 - 887400;
        // return prStartTick(tickToPr(tick - 1));
    }

    // function tickPoint(int24 tick) internal pure returns (int24) {
    //     return (tick / 600) * 600 - (tick < 0 ? 600 : 0);
    // }


    function prTime(
        uint256 prTimeSlot,
        uint256 prId
    ) internal pure returns (uint32){
        uint256 shift = prId % 8;
        return uint32( prTimeSlot >> (224 - 32 * shift));
    }

    function prTimeIndex(
        uint256 prId,
        uint256 time
    ) internal pure returns (uint256){
        return time * 100000 + prId;
    }


    function prArray(
        uint256[370] storage self,
        uint256 prStart,
        uint256 prEnd,
        bool isPrice
    ) internal view returns (uint256[] memory) {
        uint256 s = prToPs(prStart);
        uint256 e = prToPs(prEnd);
        require(e >=s, "e<s");
        uint256 l = e - s + 1;

        uint256[] memory ar = new uint256[](l);
        if (isPrice){
            for (uint i = 0; i < l; i++) {
                ar[i] = self[s + i];
                if (ar[i] < 1)
                    ar[i] = 2695994667342774153151519748852660538204866229735529663432689398579300000000;
            }
        }
        else{
            for (uint i = 0; i < l; i++) {
                ar[i] = self[s + i];
            } 
        }
        return ar;
    }


    function updatePositionEntryPrice(
        uint256 entryLiq,
        uint256 entryPrice,
        uint256 newLiq,
        uint256 curPrice
    ) internal pure returns (uint256) {
        // entryLiqNow + newRealLiq = (positinLiq + newRealLiq) / avePrice * newPrice
        // positinLiq / entryPrice * newPrice + newRealLiq = (positinLiq + newRealLiq) * newPrice / avePrice
        // avePrice = (positinLiq + newRealLiq) * newPrice / (positinLiq * newPrice / entryPrice  + newRealLiq)
        uint256 positionRealLiq = FullMath.mulDiv(entryLiq, curPrice, entryPrice);
        return FullMath.mulDiv(entryLiq + newLiq, curPrice, positionRealLiq + newLiq);
    }



    function updateU32Slot(
        uint256 slotValue,
        uint256 prId,
        uint256 value
    ) internal pure returns (uint256) {
        uint256 lc = 224 - 32 * (prId % 8);
        slotValue = slotValue & (~(0xFFFFFFFF << lc));
        slotValue = slotValue | ((0xFFFFFFFF & value) <<lc);
        return slotValue;
    }


    function priceInPs(
        uint256 priceSlot,
        uint256 prId
    ) internal pure returns (uint32) {
        return uint32(priceSlot >> (224 - (32 * (prId % 8))));
    }



    function loadPriceslot(
        uint256[370] storage self,
        uint256 psId
    ) internal view returns (uint256) {
        uint256 ps = self[psId];
        return
            ps > 0
                ? ps
                : 2695994667342774153151519748852660538204866229735529663432689398579300000000;
    }

    function loadPrPrice(
        uint256[370] storage self,
        uint256 prId
    ) internal view returns (uint256) {
        uint256 ps = self[prId / 8];
        if (ps > 0) {
            return priceInPs(ps, prId);
        } else {
            return PRP_PREC;
        }
    }

    function writePriceSlot(
        uint256[370] storage self,
        uint256 psId,
        uint256 latestPs
    ) internal {
        self[psId] = latestPs > 0
            ? latestPs
            : 2695994667342774153151519748852660538204866229735529663432689398579300000000;
    }

    function writeTimeSlot(
        uint256[370] storage self,
        uint256 psId,
        uint256 latestPs
    ) internal {
        require(latestPs > 0, "t");
        self[psId] = latestPs;
    }
    
    
    function updatePrice(
        uint256 realLiq,
        uint256 liqDelta,
        uint256 curPrice,
        bool burn
    ) internal pure returns (uint32) {
        if (curPrice < 1) return 0;
        if (burn)
            require(realLiq > liqDelta, "price=0");

        //  supLiq  = realLiq / curPrice
        // newPrice = (realLiq + delta) / supLiq
        //          = (realLiq + delta) * curPrice / realLiq
        uint256 latPrice = FullMath.mulDiv(
                        uint256(burn ? realLiq - liqDelta : realLiq + liqDelta),
                        curPrice,
                        realLiq
                    );
        return uint32(latPrice > 0xFFFFFFFF ? 0xFFFFFFFF : latPrice);
    }


    // info stored for each initialized individual tick
    struct FeeInfo {
        uint128 spotFee0X128;
        uint128 spotFee1X128;
        uint128 perpFee0X128;
        uint128 perpFee1X128;
    }


    function clear(mapping(uint256 => PriceRange.FeeInfo) storage self, uint256 pr) internal {
        delete self[pr];
    }

    function updateSpotFee(
        mapping(uint256 => PriceRange.FeeInfo) storage self,
        uint256 cacheTime,
        uint256 curTime,
        uint256 pr,
        bool zeroForOne,
        uint256 feeDelta,
        uint256 liquidity,
        uint256 price
    ) internal {
        PriceRange.FeeInfo memory info = self[prTimeIndex(pr, cacheTime)];
        if (price > 0){
            feeDelta = FullMath.mulDiv(
                feeDelta,
                FixedPoint128.Q128,
                liquidity * PriceRange.PRP_PREC / price);

            // convert real liquidity to supply liquidity
            if (zeroForOne)
                info.spotFee0X128 += uint128(feeDelta);
            else
                info.spotFee1X128 += uint128(feeDelta);
        }
        self[prTimeIndex(pr, curTime)] = info;
    }

    function updatePerpFee(
        mapping(uint256 => PriceRange.FeeInfo) storage self,
        uint256 cacheTime,
        uint256 curTime,
        uint16 pr,
        uint256 price,
        uint256 liq,
        uint256 feeDelta,
        bool long0  //Token 0 for long0
    ) internal {
        PriceRange.FeeInfo memory info = self[prTimeIndex(pr, cacheTime)];

        if (price > 0){
            feeDelta = FullMath.mulDiv(
                feeDelta,
                FixedPoint128.Q128,
                liq * PRP_PREC / uint256(price)
            );
            // convert real liquidity to supply liquidity
            if (long0)
                info.perpFee0X128 += uint128(feeDelta);
            else
                info.perpFee1X128 += uint128(feeDelta);
        }
        self[prTimeIndex(pr, curTime)] = info;
        // update co-slot
        // update in main code to save gas.
        // if (pr%2 > 0){
        //     self[PriceRange.prTimeIndex(pr-1, curTime)]
        //         = self[PriceRange.prTimeIndex(pr-1, cacheTime)];
        // } else {
        //     self[PriceRange.prTimeIndex(pr+1, curTime)]
        //         = self[PriceRange.prTimeIndex(pr+1, cacheTime)];
        // }
    }


 


    function feeCollect(
        uint256 entryLiq,
        uint256 entryFee,
        uint256 curFee
    ) internal pure returns (uint128){
        if (curFee <= entryFee)
            return 0;
            
        return uint128(FullMath.mulDiv(
                    curFee - entryFee,
                    entryLiq,
                    FixedPoint128.Q128
                ));
    }

}
