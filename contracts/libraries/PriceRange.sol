// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import './LowGasSafeMath.sol';
import './SafeCast.sol';

import './TickMath.sol';
import './LiquidityMath.sol';
import "./FullMath.sol";
import './FixedPoint128.sol';


library PriceRange {
    using LowGasSafeMath for int256;
    using SafeCast for int256;

    // info stored for each initialized individual tick
    struct Info {
        // int128 liquidityGross;
        // uint32 price;
        // uint256 fee0X128;
        // uint256 fee1X128;
        uint128 spotFee0X128;
        uint128 spotFee1X128;
        uint128 perpFee0X128;
        uint128 perpFee1X128;
    }

    function tickToPr(int24 tick) internal pure returns (uint256) {
        tick = (tick + 887272) / 600;
        require(tick >= 0);
        return uint256(tick);
    }

    function clear(mapping(uint256 => PriceRange.Info) storage self, uint256 pr) internal {
        delete self[pr];
    }


    function prTime(
        uint256 prTimeSlot,
        uint256 prId
    ) internal pure returns (uint256){
        uint256 shift = (prId % 12 ) / 2;
        return 0x3FFFFFFFFFF & ( prTimeSlot >> (213 - 42 * shift ));
    }


    function prTimeId(
        uint256 prId,
        uint256 time
    ) internal pure returns (uint256){
        return time * 10000 + prId;
    }



    function updatePrTime(
        uint256 prTimeSlot,
        uint256 prId,
        uint256 time
    ) internal pure returns (uint256){
        uint256 shift = (prId % 12 ) / 2;
        uint256 mask = 0x3FFFFFFFFFF << (213 - 42 * shift );
        prTimeSlot = prTimeSlot & (~mask);
        prTimeSlot = prTimeSlot | (time << (213 - 42 * shift ));
        return prTimeSlot;
    }



    function updatePerpFee(
        mapping(uint256 => PriceRange.Info) storage self,
        uint256 cacheTime,
        uint256 curTime,
        uint16 pr,
        uint32 price,
        uint256 liq,
        uint256 feeDelta,
        bool long0  //Token 0 for long0
    ) internal {
        PriceRange.Info memory info = self[prTimeId(pr, cacheTime)];

        if (price > 0){
            // convert real liquidity to supply liquidity
            feeDelta = FullMath.mulDiv(feeDelta, liq * 10000 / uint256(price), FixedPoint128.Q128);
            if (long0)
                info.perpFee0X128 += uint128(feeDelta);
            else
                info.perpFee1X128 += uint128(feeDelta);
        }
        self[prTimeId(pr, curTime)] = info;

        // update co-slot
        // update in main code to save gas.
        // if (pr%2 > 0){
        //     self[PriceRange.prTimeId(pr-1, curTime)]
        //         = self[PriceRange.prTimeId(pr-1, cacheTime)];
        // } else {
        //     self[PriceRange.prTimeId(pr+1, curTime)]
        //         = self[PriceRange.prTimeId(pr+1, cacheTime)];
        // }
    }


    function updateSpotFee(
        mapping(uint256 => PriceRange.Info) storage self,
        uint256 cacheTime,
        uint256 curTime,
        uint256 pr,
        bool zeroForOne,
        uint128 feeX128
    ) internal {
        PriceRange.Info memory info = self[prTimeId(pr, cacheTime)];
        if (feeX128 < 1)
            return;
        if (zeroForOne){
            info.spotFee1X128 += feeX128;
        }else{
            info.spotFee0X128 += feeX128;
        }
        
        self[prTimeId(pr, curTime)] = info;
        //update co-slot
        if (pr%2 > 0){
            self[PriceRange.prTimeId(pr-1, curTime)]
                = self[PriceRange.prTimeId(pr-1, cacheTime)];
        } else {
            self[PriceRange.prTimeId(pr+1, curTime)]
                = self[PriceRange.prTimeId(pr+1, cacheTime)];
        }

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


    function curPrTime(
        uint256[247] storage self,
        uint256 pr
    ) internal view returns (uint256){
        return prTime(self[pr / 12], pr);
    }


}
