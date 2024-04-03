// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../interfaces/IRoguexFactory.sol";
import "../interfaces/IRoxPerpPoolDeployer.sol";
import "../interfaces/IRoxSpotPool.sol";
import "../interfaces/IRoxPosnPool.sol";
import "../interfaces/IRoxPerpPool.sol";
import "../interfaces/IERC20Minimal.sol";
import '../interfaces/external/IWETH9.sol';
import "../interfaces/IRoxUtils.sol";
import "../libraries/TransferHelper.sol";
import "../libraries/TradeData.sol";
import "../libraries/TradeMath.sol";
import "../libraries/FullMath.sol";
import "../libraries/TickMath.sol";
import "../libraries/SqrtPriceMath.sol";
import '../libraries/PriceRange.sol';
import '../libraries/PosRange.sol';
import "../libraries/LowGasSafeMath.sol";


contract TestPerp  {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for uint128;
    using PosRange for mapping(uint128 => uint256);

    IRoxUtils public immutable roxUtils;

    constructor(address _roxU){
        roxUtils = IRoxUtils(_roxU);
    }

    struct SettleCache{
        int24 tmpSht;
        int24 tickCur;
        int24 startTickRound;
        uint24 startPs;
        uint16 startPr;
        uint16 psId;
        uint16 prId;
        uint32 psTime;
        uint32 prCacheTime;
        uint32 curTime;
        //---slot----
        
        uint128 feeDt;
        uint128 feeCache;
        //---slot----

        uint128 liqDelta;
        uint128 endLiq;

        uint256 liqSum;
        uint256 curPriceSlot;
        uint256 curPrTimeSlot;
        uint256 resvCache;
    }

    function settle0(
        address spotPool,
        address posnPool,
        bool _burn,
        uint256 _tokenAmount,
        uint256 _feeAmount,
        uint256 _resvAmount
    ) public {
        SettleCache memory bCache;
        ( , bCache.tickCur , , , , , ) = IRoxSpotPool(spotPool).slot0();
        // bCache.startTickRound = PriceRange.rightBoundaryTick(bCache.tickCur);

        bCache.resvCache = _resvAmount;

        if (_burn)
            require(_tokenAmount <= bCache.resvCache, "l");
        uint256[] memory liqL;
        (liqL, bCache.endLiq, bCache.liqSum, bCache.startTickRound) = roxUtils.getLiqArray(
                    spotPool,
                    true,
                    bCache.resvCache
                );
        require(liqL.length > 0, "c");

        (bCache.startPr, bCache.startPs) = PriceRange.tickTo(bCache.startTickRound);

        bCache.curTime = uint32(block.timestamp);

        for(uint i = 0; i < liqL.length; i+=2){
            (bCache.prId, bCache.psId) = PriceRange.tickTo(bCache.startTickRound + bCache.tmpSht);
            if ( (i+2 == liqL.length)){
                bCache.liqDelta = uint128(FullMath.mulDiv(bCache.endLiq, _tokenAmount, bCache.resvCache));
                bCache.feeCache = uint128(FullMath.mulDiv(_feeAmount, bCache.endLiq, bCache.liqSum));
            }
            else{
                bCache.liqDelta = uint128(FullMath.mulDiv(liqL[i], _tokenAmount, bCache.resvCache));
                bCache.feeCache = uint128(FullMath.mulDiv(_feeAmount, liqL[i], bCache.liqSum));
            }

            if (bCache.curPriceSlot < 1){ 
                bCache.curPriceSlot = IRoxPosnPool(posnPool).priceSlot(bCache.psId);
                bCache.curPrTimeSlot = IRoxPosnPool(posnPool).timeSlot(bCache.psId);
                bCache.prCacheTime = PriceRange.prTime(bCache.curPrTimeSlot, bCache.prId);
            }

            //TODO:  combine update perpPositions with same liquidity to save gas

            // Update P.R in current P.S
            // uint32 priceL = bCache.psTime > 0 ? TradeMath.priceInPs(priceSlot[bCache.psTime + bCache.psId], bCache.psId) : 1e4;
            uint256 priceL = PriceRange.priceInPs(bCache.curPriceSlot, bCache.prId);

            // stop pnl update when price is too high or too low .
            if ( (priceL >= PriceRange.PRP_MAXP && !_burn)
                || (priceL <= PriceRange.PRP_MINP && _burn) ){
                uint128 _profit = uint128(FullMath.mulDiv(liqL[i+1], _tokenAmount, bCache.resvCache));
                require(_tokenAmount >= _profit, "t");
                _tokenAmount -= _profit;
                // _tokenAmount = _tokenAmount.sub(_profit);   
                if (!_burn){
                    // do not update price
                    bCache.feeCache += _profit;
                    bCache.feeDt += _profit;
                }
                bCache.liqDelta = 0;
            }else{
                IRoxSpotPool(spotPool).updatePnl(
                    bCache.startTickRound + bCache.tmpSht, 
                    bCache.startTickRound + (bCache.tmpSht+= 600), 
                    bCache.tickCur,
                    _burn ? -int128(bCache.liqDelta) : int128(bCache.liqDelta));

                priceL = PriceRange.updatePrice(liqL[i], bCache.liqDelta, priceL, _burn);
                bCache.curPriceSlot = PriceRange.updateU32Slot(bCache.curPriceSlot, bCache.prId, priceL);
            }

            // Fee Distribution is different from liq. dist.
            // TODO: already calculated in previous update price
            //       combine function variables to save gas.
            
            IRoxPosnPool(posnPool).updatePerpFee(
                bCache.curTime,
                bCache.prId,
                priceL,
                _burn ? liqL[i] - bCache.liqDelta  : liqL[i] + bCache.liqDelta,
                bCache.feeCache,
                true);
        

            bCache.curPrTimeSlot = PriceRange.updateU32Slot(bCache.curPrTimeSlot, bCache.prId, bCache.curTime);

            //update current price slot if next cross or latest loop
            if (PriceRange.isRightCross(bCache.prId) || i >= liqL.length -2){ 
                IRoxPosnPool(posnPool).writePriceSlot(bCache.psId, bCache.curPriceSlot);//sWrite to update
                bCache.curPriceSlot = 0;//renew pSlot
                // bCache.curPriceSlot = 0; //do not need reset
            } 
        }
        _feeAmount += bCache.feeDt;
        // if (_burn){
        //     // _is0 ? _transferOut0(_feeAmount, spotPool, false) : _transferOut1(_feeAmount, spotPool, false);
        //     _transferOut(_is0, _feeAmount, spotPool, false);
        // }
        // else{
        //     // _is0 ? _transferOut0(_tokenAmount + _feeAmount, spotPool, false) : _transferOut1(_tokenAmount + _feeAmount, spotPool, false);
        //     _transferOut(_is0, _tokenAmount + _feeAmount, spotPool, false);
        // }

        address _tToken = IRoxSpotPool(spotPool).token0();
        TransferHelper.safeTransferFrom(_tToken, msg.sender, spotPool, _feeAmount + (_burn? 0 : _tokenAmount));

        if (_burn)
            IRoxSpotPool(spotPool).perpSettle(_tokenAmount, true, msg.sender);        
    }


}
