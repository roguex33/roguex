// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "./libraries/LowGasSafeMath.sol";
import "./interfaces/IRoxPerpPool.sol";
import "./interfaces/IRoxPosnPool.sol";
import "./interfaces/IRoxPosnPoolDeployer.sol";
import "./libraries/PositionKey.sol";
import "./libraries/TradeMath.sol";
import "./libraries/RoxPosition.sol";
import "./libraries/SafeCast.sol";
import "./libraries/Tick.sol";
import "./libraries/FullMath.sol";
import './libraries/PriceRange.sol';

contract RoxPosnPool is IRoxPosnPool {
    using LowGasSafeMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using PriceRange for uint256[370];
    using PriceRange for mapping(uint256 => PriceRange.FeeInfo);

    // price = realLiq / supLiq 
    // position realLiq = entrySupLiq * latestPrice
    //                  = entryRealLiq / entryPrice * latestPrice
    // supLiq = realLiq / price
    mapping(bytes32 => RoxPosition.Position) public roxPositions;

    // Price related.
    // Price Range:
    //      priceRangeId = (curTick + 887272)/600; NameAs => pr /@ max value = 887272 * 2(1774544Ticks) / 600 = 2958 PriceRanges
    // Price Slot:
    //      every 8 price Range(32bitPerId) stored in one uint256 slot,
    //      psId : 0 ~ 369      (2958 / 8 = 370)
    //      price Tick SlotId = priceRangeId / 8; 
    //      update time: u32,
    uint256[370] private priceSlots;
    uint256[370] public override timeSlots;  
    mapping(uint256 => PriceRange.FeeInfo) public prs;






    address immutable public factory;
    address immutable public token0;
    address immutable public token1;
    address immutable public spotPool;
    address immutable public perpPool;
    
    modifier onlySpotPool() {
        require(msg.sender == spotPool, "Not approved");
        _;
    }

    constructor (){
        (
            factory,
            token0,
            token1, 
            ,
            spotPool,
            perpPool
        ) = IRoxPosnPoolDeployer(msg.sender).parameters();
    }


    function priceSlot(uint psId) public view override returns (uint256){
        return priceSlots.loadPriceslot(psId);
    }
    

    function timeSlot(uint psId) public view override returns (uint256){
        return timeSlots[psId];
    }
    


    function prInfo(
        uint256 timePr
    ) external override view returns (PriceRange.FeeInfo memory){
        return prs[timePr];
    }

    function writePriceSlot(
            uint16 _psId,
            uint256 _priceSlot) external override {
        require(msg.sender == perpPool, "xPp");
        priceSlots.writePriceSlot(_psId, _priceSlot);
    }

    function writeTimeSlot(
            uint16 _psId,
            uint256 _timeSlot) external override {
        require(msg.sender == perpPool, "xPp");
        timeSlots.writeTimeSlot(_psId, _timeSlot);
    }

    function updatePerpFee(
        uint256 cacheTime,
        uint256 curTime,
        uint16 pr,
        uint256 price,
        uint256 liq,
        uint256 feeDelta,
        bool long0) external override {
        require(msg.sender == perpPool, "xPp");
        prs.updatePerpFee(
            cacheTime,
            curTime,
            pr,
            price,
            liq,
            feeDelta,
            long0);
    }


    function updateSwapFee(
        int24 tick,
        bool zeroForOne,
        uint256 feeToken,
        uint256 liquidity
    ) external override {
        require(msg.sender == spotPool);
        (uint16 pr, uint16 ps) = PriceRange.tickTo(tick);
        uint256 price = priceSlots.loadPrPrice(pr);
        uint256 slotCache = timeSlots[ps];
        uint256 curTime = block.timestamp;
        if (price < 1)
            return;
        // recalculate fee according to supply-liquidity  
        prs.updateSpotFee(
            PriceRange.prTime(slotCache, pr), 
            curTime, pr, zeroForOne, feeToken, liquidity, price );
        timeSlots[ps] = PriceRange.updateU32Slot(slotCache, pr, curTime);
    }
    
    function encodeSlots(
        uint256 prStart, uint256 prEnd, bool isPrice
        ) public override view returns (uint256[] memory s) {
        if (isPrice)
            return priceSlots.prArray(prStart, prEnd, true);
        else
            return timeSlots.prArray(prStart, prEnd, false);
    }






    function positions(bytes32 key)
        public
        override
        view
        returns ( 
            uint128 liquidity,
            uint128 spotFeeOwed0,
            uint128 spotFeeOwed1,
            uint128 perpFeeOwed0,
            uint128 perpFeeOwed1,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ){
            RoxPosition.Position memory _positions = roxPositions[key];
            return (_positions.liquidity, 
                _positions.spotFeeOwed0,
                _positions.spotFeeOwed1,
                _positions.perpFeeOwed0,
                _positions.perpFeeOwed1,
                _positions.tokensOwed0,
                _positions.tokensOwed1
            );
        }

    function positionsSum(bytes32 key)
        public
        override
        view
        returns ( 
            uint128 ,
            uint256 ,
            uint256 ,
            uint128 ,
            uint128 
        ){
            RoxPosition.Position memory _positions = roxPositions[key];
            return (_positions.liquidity, 
                _positions.spotFeeOwed0 + _positions.perpFeeOwed0,
                _positions.spotFeeOwed1 + _positions.perpFeeOwed1,
                _positions.tokensOwed0,
                _positions.tokensOwed1
            );
    }


    function increaseLiquidity(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDelta
        ) public override onlySpotPool{
        bytes32 _key = PositionKey.compute(
                        owner,
                        tickLower,
                        tickUpper
                    );
        // RoxPosition.Position memory position = self[_key];


        RoxPosition.Position memory position = roxPositions[_key];
        if(position.owner == address(0)){
            position.owner = owner;
            position.tickLower = tickLower;
            position.tickUpper = tickUpper;
        }

        UpdCache memory dCache;

        dCache.prStart = uint16(PriceRange.tickToPr(position.tickLower));
        dCache.prEnd = uint16(PriceRange.tickToPr(position.tickUpper));
        dCache.tickLower = position.tickLower;
        // RoxPosition.checkTick(position.tickLower, position.tickUpper);

        // Update if liquidity > 0
        if (position.liquidity > 0 && position.priceMap.length > 0){
            dCache.entryPriceSlot = position.priceMap[0];
            for(uint16 prLoop = dCache.prStart; prLoop < dCache.prEnd; prLoop++){
                if (dCache.curPriceSlot < 1 || PriceRange.isLeftCross(prLoop)){ 
                    dCache.entryTimeSlot = position.timeMap[dCache.prId];
                    dCache.curTimeSlot = timeSlots[PriceRange.prToPs(prLoop)];
                    dCache.entryPriceSlot = position.priceMap[dCache.prId];
                    dCache.curPriceSlot = priceSlot(PriceRange.prToPs(prLoop));
                    dCache.prId += 1;
                }
                dCache.entryPrice = PriceRange.priceInPs(dCache.entryPriceSlot, prLoop);
                dCache.curPrice = PriceRange.priceInPs(dCache.curPriceSlot, prLoop);

                dCache.entryTime = PriceRange.prTime(dCache.entryTimeSlot, prLoop);
                dCache.curTime = PriceRange.prTime(dCache.curTimeSlot, prLoop);

                //fee settle
                if (dCache.entryPrice > 0) {
                    PriceRange.FeeInfo memory prEntry = prs[PriceRange.prTimeIndex(prLoop, dCache.entryTime)];
                    PriceRange.FeeInfo memory prCur = prs[PriceRange.prTimeIndex(prLoop, dCache.curTime)];
                    uint256 entrySupLiq = uint256(position.liquidity) * PriceRange.PRP_PREC / dCache.entryPrice;
                    position.spotFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee0X128, prCur.spotFee0X128);
                    position.spotFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee1X128, prCur.spotFee1X128);
                    position.perpFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee0X128, prCur.perpFee0X128);
                    position.perpFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee1X128, prCur.perpFee1X128);           
                }

                {
                    // entryLiqNow + newRealLiq = (positinLiq + newRealLiq) / avePrice * newPrice
                    // positinLiq / entryPrice * newPrice + newRealLiq = (positinLiq + newRealLiq) * newPrice / avePrice
                    // avePrice = (positinLiq + newRealLiq) * newPrice / (positinLiq * newPrice / entryPrice  + newRealLiq)
                    dCache.entryPriceSlot = PriceRange.updateU32Slot(
                                dCache.entryPriceSlot, 
                                prLoop,
                                PriceRange.updatePositionEntryPrice(
                                        position.liquidity,
                                        dCache.entryPrice,
                                        liquidityDelta,
                                        dCache.curPrice)
                                );
                }
                if (prLoop == dCache.prEnd || PriceRange.isRightCross(prLoop)){ 
                    position.priceMap[dCache.prId] = dCache.entryPriceSlot;
                }
            }

        }
        else{
            position.priceMap = encodeSlots(dCache.prStart, dCache.prEnd, true);
        }

        position.timeMap = encodeSlots(dCache.prStart, dCache.prEnd, false);
        position.liquidity = position.liquidity + liquidityDelta;
        roxPositions[_key] = position;
        // return position;
    }

    function collect(
        // mapping(bytes32 => Position) storage self,
        bytes32 _key,
        uint128 _amount0Requested,
        uint128 _amount1Requested) public override onlySpotPool returns (uint128 amount0, uint128 amount1) {
        // we don't need to checkTicks here, because invalid positions will never have non-zero tokensOwed{0,1}
        // RoxPosition.Position storage position = positions.get(msg.sender, tickLower, tickUpper);
        RoxPosition.Position storage position = roxPositions[_key];

        amount0 = _amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : _amount0Requested;
        amount1 = _amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : _amount1Requested;
    
        position.tokensOwed0 -= amount0;
        position.tokensOwed1 -= amount1;

        amount0 += position.spotFeeOwed0;
        amount0 += position.perpFeeOwed0;
        amount1 += position.spotFeeOwed1;
        amount1 += position.perpFeeOwed1;

        position.spotFeeOwed0 = 0;
        position.spotFeeOwed1 = 0;
        position.perpFeeOwed0 = 0;
        position.perpFeeOwed1 = 0;
    }

    function updateFee(
        // mapping(bytes32 => Position) storage self,
        bytes32 _key
    ) public override  {//onlySpotPool
        RoxPosition.Position memory position = roxPositions[_key];
        UpdCache memory dCache;
        if (position.owner == address(0))
            return ;

        if (position.liquidity < 1 || position.priceMap.length < 1)
            return ;
            
        dCache.prStart = uint16(PriceRange.tickToPr(position.tickLower));
        dCache.prEnd = uint16(PriceRange.tickToPr(position.tickUpper));
        // Update if liquidity > 0
        dCache.entryPriceSlot = position.priceMap[0];
        for(uint16 prLoop = dCache.prStart; prLoop < dCache.prEnd; prLoop++){
            if (dCache.curPriceSlot < 1 || PriceRange.isLeftCross(prLoop)){ 
                uint256 _ps = PriceRange.prToPs(prLoop);
                dCache.entryTimeSlot = position.timeMap[dCache.prId];
                dCache.curTimeSlot = timeSlots[_ps];
                dCache.entryPriceSlot = position.priceMap[dCache.prId];
                dCache.curPriceSlot = priceSlot(_ps);
                dCache.prId += 1;
            }
            dCache.entryPrice = PriceRange.priceInPs(dCache.entryPriceSlot, prLoop);
            dCache.entryTime = PriceRange.prTime(dCache.entryTimeSlot, prLoop);
            dCache.curTime = PriceRange.prTime(dCache.curTimeSlot, prLoop);
            
            if (dCache.curTime > dCache.entryTime && dCache.entryPrice > 0){          
                //fee settle
                PriceRange.FeeInfo memory prEntry = prs[PriceRange.prTimeIndex(prLoop, dCache.entryTime)];
                PriceRange.FeeInfo memory prCur = prs[PriceRange.prTimeIndex(prLoop, dCache.curTime)];

                uint256 entrySupLiq = FullMath.mulDiv(position.liquidity,  PriceRange.PRP_PREC,  dCache.entryPrice);
                position.spotFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee0X128, prCur.spotFee0X128);
                position.spotFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee1X128, prCur.spotFee1X128);
                position.perpFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee0X128, prCur.perpFee0X128);
                position.perpFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee1X128, prCur.perpFee1X128);
            }
        } 
        // Update to latesr time slots
        position.timeMap = encodeSlots(dCache.prStart, dCache.prEnd, false);
        roxPositions[_key] = position;
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

        uint32 curPrice;
        uint32 entryPrice;
        uint32 entryTime;
        uint32 curTime;
    }


    function decreaseLiquidity(
        bytes32 _key,
        uint128 liquidityDelta,
        int24 tick,
        uint160 sqrtPriceX96
    ) external override onlySpotPool returns (uint128[] memory liqDelta, uint256 amount0, uint256 amount1){

        RoxPosition.Position memory position = roxPositions[_key];
        UpdCache memory dCache;
        require(position.liquidity >= liquidityDelta, "out of liq burn");

        // // uint128 positionLiquidity_p = params.liquidity;// * price
        dCache.prStart = uint16(PriceRange.tickToPr(position.tickLower));
        dCache.prEnd = uint16(PriceRange.tickToPr(position.tickUpper));


        dCache.tickLower = position.tickLower;
        liqDelta = new uint128[]( uint(position.tickUpper - position.tickLower) / 600);
        // uint256 amount0;
        // uint256 amount1;
        // Update if liquidity > 0
        if (position.priceMap.length > 0){
            dCache.entryPriceSlot = position.priceMap[0];
            uint i = 0;
            for(uint16 prLoop = dCache.prStart; prLoop < dCache.prEnd; prLoop++){
                if (dCache.curPriceSlot < 1 || PriceRange.isLeftCross(prLoop)){ 
                    uint256 _ps = PriceRange.prToPs(prLoop);
                    dCache.entryTimeSlot = position.timeMap[dCache.prId];
                    dCache.curTimeSlot = timeSlots[_ps];
                    dCache.entryPriceSlot = position.priceMap[dCache.prId];
                    dCache.curPriceSlot = priceSlot(_ps);
                    dCache.prId += 1;
                }
                dCache.entryPrice = PriceRange.priceInPs(dCache.entryPriceSlot, prLoop);
                dCache.curPrice = PriceRange.priceInPs(dCache.curPriceSlot, prLoop);
                //TODO: combine 0 & 1 to save gas
                dCache.entryTime = PriceRange.prTime(dCache.entryTimeSlot, prLoop);
                dCache.curTime = PriceRange.prTime(dCache.curTimeSlot, prLoop);

                //fee settle
                if (dCache.entryPrice > 0) {
                    PriceRange.FeeInfo memory prEntry = prs[PriceRange.prTimeIndex(prLoop, dCache.entryTime)];
                    PriceRange.FeeInfo memory prCur = prs[PriceRange.prTimeIndex(prLoop, dCache.curTime)];
                    uint256 entrySupLiq = uint256(position.liquidity) * PriceRange.PRP_PREC / dCache.entryPrice;
                    position.spotFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee0X128, prCur.spotFee0X128);
                    position.spotFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee1X128, prCur.spotFee1X128);
                    position.perpFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee0X128, prCur.perpFee0X128);
                    position.perpFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee1X128, prCur.perpFee1X128);           
                }

                 //TODO: combine burn to save gas
                // if (dCache.entryPrice != dCache.curPrice || prs == endPr){
                {
                    dCache.liquidity = TradeMath.liqTrans(liquidityDelta, dCache.entryPrice, dCache.curPrice);
                    liqDelta[i] = dCache.liquidity;
                    // liqRatio[i+1] = dCache.curPrice;
                    i += 1;

                    (uint256 a0cache, uint256 a1cache) = RoxPosition.getRangeToken(dCache.liquidity, 
                            dCache.tickLower, (dCache.tickLower+=600), tick, sqrtPriceX96);
                    amount0 += a0cache;
                    amount1 += a1cache;
                }
            }
            position.tokensOwed0 += uint128(amount0);
            position.tokensOwed1 += uint128(amount1);
        }
        position.timeMap = encodeSlots(dCache.prStart, dCache.prEnd, false);
        position.liquidity = position.liquidity - liquidityDelta;
        // Do not need to update price in decrease liquidity
        roxPositions[_key] = position;
    }


 function estimateDecreaseLiquidity(
        bytes32 _key,
        uint128 liquidityDelta,
        int24 tick,
        uint160 sqrtPriceX96
    ) external override view returns (uint256 amount0, uint256 amount1){

        RoxPosition.Position memory position = roxPositions[_key];
        UpdCache memory dCache;
        require(position.liquidity >= liquidityDelta, "out of liq burn");

        // // uint128 positionLiquidity_p = params.liquidity;// * price
        dCache.prStart = uint16(PriceRange.tickToPr(position.tickLower));
        dCache.prEnd = uint16(PriceRange.tickToPr(position.tickUpper));
        dCache.tickLower = position.tickLower;


        // Update if liquidity > 0
        if (position.priceMap.length > 0){
            dCache.entryPriceSlot = position.priceMap[0];
            for(uint16 prLoop = dCache.prStart; prLoop < dCache.prEnd; prLoop++){
                if (dCache.curPriceSlot < 1 || PriceRange.isLeftCross(prLoop)){ 
                    uint256 _ps = PriceRange.prToPs(prLoop);
                    dCache.entryTimeSlot = position.timeMap[dCache.prId];
                    dCache.curTimeSlot = timeSlots[_ps];
                    dCache.entryPriceSlot = position.priceMap[dCache.prId];
                    dCache.curPriceSlot = priceSlot(_ps);
                    dCache.prId += 1;
                }
                dCache.entryPrice = PriceRange.priceInPs(dCache.entryPriceSlot, prLoop);
                dCache.curPrice = PriceRange.priceInPs(dCache.curPriceSlot, prLoop);
                //TODO: combine 0 & 1 to save gas
                dCache.entryTime = PriceRange.prTime(dCache.entryTimeSlot, prLoop);
                dCache.curTime = PriceRange.prTime(dCache.curTimeSlot, prLoop);

                 //TODO: combine burn to save gas
                // if (dCache.entryPrice != dCache.curPrice || prs == endPr){
                {
                    dCache.liquidity = TradeMath.liqTrans(liquidityDelta, dCache.entryPrice, dCache.curPrice);
                    (uint256 a0cache, uint256 a1cache) = RoxPosition.getRangeToken(dCache.liquidity, 
                            dCache.tickLower, (dCache.tickLower+=600), tick, sqrtPriceX96);
                    amount0 += a0cache;
                    amount1 += a1cache;
                }
            }
        }
    }



    function pendingFee(
        bytes32 _key
    ) external override view returns (
            uint128 tokenOw0, uint128 tokenOw1,
            uint128 spotFeeOwed0, uint128 spotFeeOwed1, uint128 perpFeeOwed0, uint128 perpFeeOwed1) {
        RoxPosition.Position memory position = roxPositions[_key];
        
        if (position.liquidity > 0){
            UpdCache memory dCache;
            dCache.prStart = uint16(PriceRange.tickToPr(position.tickLower));
            dCache.prEnd = uint16(PriceRange.tickToPr(position.tickUpper));
            // Update if liquidity > 0
            dCache.entryPriceSlot = position.priceMap[0];
            for(uint16 prLoop = dCache.prStart; prLoop < dCache.prEnd; prLoop++){
                if (dCache.curPriceSlot < 1 || PriceRange.isLeftCross(prLoop)){ 
                    uint256 _ps = PriceRange.prToPs(prLoop);
                    dCache.entryTimeSlot = position.timeMap[dCache.prId];
                    dCache.curTimeSlot = timeSlots[_ps];
                    dCache.entryPriceSlot = position.priceMap[dCache.prId];
                    dCache.curPriceSlot = priceSlot(_ps);
                    dCache.prId += 1;
                }
                dCache.entryPrice = PriceRange.priceInPs(dCache.entryPriceSlot, prLoop);
                dCache.entryTime = PriceRange.prTime(dCache.entryTimeSlot, prLoop);
                dCache.curTime = PriceRange.prTime(dCache.curTimeSlot, prLoop);
                
                if (dCache.curTime > dCache.entryTime && dCache.entryPrice > 0){
                    PriceRange.FeeInfo memory prEntry = prs[PriceRange.prTimeIndex(prLoop, dCache.entryTime)];
                    PriceRange.FeeInfo memory prCur = prs[PriceRange.prTimeIndex(prLoop, dCache.curTime)];
                    uint256 entrySupLiq = FullMath.mulDiv(position.liquidity,  PriceRange.PRP_PREC,  dCache.entryPrice);
                    position.spotFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee0X128, prCur.spotFee0X128);
                    position.spotFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee1X128, prCur.spotFee1X128);
                    position.perpFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee0X128, prCur.perpFee0X128);
                    position.perpFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee1X128, prCur.perpFee1X128);
                }
            } 
        }
        return (position.tokensOwed0,
                position.tokensOwed1,
                position.spotFeeOwed0,
                position.spotFeeOwed1,
                position.perpFeeOwed0,
                position.perpFeeOwed1);
    }


}