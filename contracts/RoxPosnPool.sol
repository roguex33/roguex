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

    // price = realLiq / supLiq 
    // position realLiq = entrySupLiq * latestPrice
    //                  = entryRealLiq / entryPrice * latestPrice
    // supLiq = realLiq / price
    mapping(bytes32 => RoxPosition.Position) public roxPositions;

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
                    dCache.curTimeSlot = IRoxPerpPool(perpPool).timeSlots(PriceRange.prToPs(prLoop));
                    dCache.entryPriceSlot = position.priceMap[dCache.prId];
                    dCache.curPriceSlot = IRoxPerpPool(perpPool).priceSlot(PriceRange.prToPs(prLoop));
                    dCache.prId += 1;
                }
                dCache.entryPrice = PriceRange.priceInPs(dCache.entryPriceSlot, prLoop);
                dCache.curPrice = PriceRange.priceInPs(dCache.curPriceSlot, prLoop);

                dCache.entryTime = PriceRange.prTime(dCache.entryTimeSlot, prLoop);
                dCache.curTime = PriceRange.prTime(dCache.curTimeSlot, prLoop);

                //fee settle
                if (dCache.entryPrice > 0) {
                    PriceRange.FeeInfo memory prEntry = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeIndex(prLoop, dCache.entryTime));
                    PriceRange.FeeInfo memory prCur = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeIndex(prLoop, dCache.curTime));
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
            position.priceMap = IRoxPerpPool(perpPool).encodeSlots(dCache.prStart, dCache.prEnd, true);
        }

        position.timeMap = IRoxPerpPool(perpPool).encodeSlots(dCache.prStart, dCache.prEnd, false);
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

        // console.log(">>>collect");
        // console.log(">>>collect");

        // console.log("ow0", position.tokensOwed0, "   ow1: ",position.tokensOwed1);
        // console.log("req0", _amount0Requested, "   req1: ",_amount0Requested);

        amount0 = _amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : _amount0Requested;
        amount1 = _amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : _amount1Requested;
        // console.log("amount0", amount0, "   amount1: ",amount1);
    
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
                dCache.curTimeSlot = IRoxPerpPool(perpPool).timeSlots(_ps);
                dCache.entryPriceSlot = position.priceMap[dCache.prId];
                dCache.curPriceSlot = IRoxPerpPool(perpPool).priceSlot(_ps);
                dCache.prId += 1;
            }
            dCache.entryPrice = PriceRange.priceInPs(dCache.entryPriceSlot, prLoop);
            dCache.entryTime = PriceRange.prTime(dCache.entryTimeSlot, prLoop);
            dCache.curTime = PriceRange.prTime(dCache.curTimeSlot, prLoop);
            
            if (dCache.curTime > dCache.entryTime && dCache.entryPrice > 0){
                // console.log("curT: ", dCache.curTime, " entryT: ", dCache.entryTime);
                // console.log("dCache.entryTimeSlot: ", dCache.entryTimeSlot, " dCache.curTimeSlot: ", dCache.curTimeSlot);
                //fee settle

                PriceRange.FeeInfo memory prEntry = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeIndex(prLoop, dCache.entryTime));
                PriceRange.FeeInfo memory prCur = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeIndex(prLoop, dCache.curTime));
                // console.log("cur spot0: ", prCur.spotFee0X128,"   cur spot1: ", prCur.spotFee1X128 );
                // console.log("ety spot0: ", prEntry.spotFee0X128,"   ety spot1: ", prEntry.spotFee1X128 );

                uint256 entrySupLiq = FullMath.mulDiv(position.liquidity,  PriceRange.PRP_PREC,  dCache.entryPrice);
                // console.log("entrySupLiq: ", entrySupLiq );
                position.spotFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee0X128, prCur.spotFee0X128);
                position.spotFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee1X128, prCur.spotFee1X128);
                // console.log("spotFeeOwed1: ", position.spotFeeOwed1 );
                position.perpFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee0X128, prCur.perpFee0X128);
                position.perpFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee1X128, prCur.perpFee1X128);
            }
        } 
        // Update to latesr time slots
        position.timeMap = IRoxPerpPool(perpPool).encodeSlots(dCache.prStart, dCache.prEnd, false);
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
        // console.log("position.liquidity", position.liquidity);
        // console.log("liquidityDelta    ", liquidityDelta);
        require(position.liquidity >= liquidityDelta, "out of liq burn");

        // // uint128 positionLiquidity_p = params.liquidity;// * price
        dCache.prStart = uint16(PriceRange.tickToPr(position.tickLower));
        dCache.prEnd = uint16(PriceRange.tickToPr(position.tickUpper));

        // console.log("dCache.prStart : ", dCache.prStart, "  dCache.end : ", dCache.prStart);
        // TradeMath.printInt("position.tickLower : ", position.tickLower);
        // TradeMath.printInt("position.tickUpper : ", position.tickUpper);

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
                    dCache.curTimeSlot = IRoxPerpPool(perpPool).timeSlots(_ps);
                    dCache.entryPriceSlot = position.priceMap[dCache.prId];
                    dCache.curPriceSlot = IRoxPerpPool(perpPool).priceSlot(_ps);
                    dCache.prId += 1;
                }
                dCache.entryPrice = PriceRange.priceInPs(dCache.entryPriceSlot, prLoop);
                dCache.curPrice = PriceRange.priceInPs(dCache.curPriceSlot, prLoop);
                //TODO: combine 0 & 1 to save gas
                dCache.entryTime = PriceRange.prTime(dCache.entryTimeSlot, prLoop);
                dCache.curTime = PriceRange.prTime(dCache.curTimeSlot, prLoop);

                //fee settle
                if (dCache.entryPrice > 0) {
                    PriceRange.FeeInfo memory prEntry = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeIndex(prLoop, dCache.entryTime));
                    PriceRange.FeeInfo memory prCur = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeIndex(prLoop, dCache.curTime));
                    uint256 entrySupLiq = uint256(position.liquidity) * PriceRange.PRP_PREC / dCache.entryPrice;
                    position.spotFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee0X128, prCur.spotFee0X128);
                    position.spotFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee1X128, prCur.spotFee1X128);
                    position.perpFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee0X128, prCur.perpFee0X128);
                    position.perpFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee1X128, prCur.perpFee1X128);           
                }

                 //TODO: combine burn to save gas
                // if (dCache.entryPrice != dCache.curPrice || prs == endPr){
                {
                    // console.log( "Entry Price: ",dCache.entryPrice,"  Curr Price: ", dCache.curPrice);
                    dCache.liquidity = TradeMath.liqTrans(liquidityDelta, dCache.entryPrice, dCache.curPrice);
                    liqDelta[i] = dCache.liquidity;
                    // liqRatio[i+1] = dCache.curPrice;
                    i += 1;

                    // console.log("entryPrice", dCache.entryPrice, "   curPrice : ", dCache.curPrice);
                    // console.log("dCache.liquidity", dCache.liquidity, "   liquidityDelta : ", liquidityDelta);
                    (uint256 a0cache, uint256 a1cache) = RoxPosition.getRangeToken(dCache.liquidity, 
                            dCache.tickLower, (dCache.tickLower+=600), tick, sqrtPriceX96);
                    amount0 += a0cache;
                    amount1 += a1cache;

                    //Update liquidity in spot pool
                    // _updateLiquidity(dCache.tickLower, dCache.tickLower + 600, -int128(dCache.liquidity), tickCur);
                    // TODO: save sqrtPrice from tick to save gas
                    // (dCache.a0cache, dCache.a1cache) = RoxPosition.getRangeToken(dCache.liquidity, 
                    //     dCache.tickLower, (dCache.tickLower += 600), tickCur, curSqrtPrice);
                    // console.log("dC.liquidity : ", dCache.liquidity);
                    // console.log("re.liquidity : ", liquidity);
                    // TradeMath.printInt("PrLoop StrTick:", TradeMath.prToTick(prLoop));
                    // TradeMath.printInt("PrLoop EndTick:", TradeMath.prToTick(prLoop+1));
                    // amount0 += dCache.a0cache;
                    // amount1 += dCache.a1cache;
                }
            }
            position.tokensOwed0 += uint128(amount0);
            position.tokensOwed1 += uint128(amount1);
        }
        // console.log("ow0", position.tokensOwed0, "   ow1: ",position.tokensOwed1);
        position.timeMap = IRoxPerpPool(perpPool).encodeSlots(dCache.prStart, dCache.prEnd, false);
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
        // console.log("position.liquidity", position.liquidity);
        // console.log("liquidityDelta    ", liquidityDelta);
        require(position.liquidity >= liquidityDelta, "out of liq burn");

        // // uint128 positionLiquidity_p = params.liquidity;// * price
        dCache.prStart = uint16(PriceRange.tickToPr(position.tickLower));
        dCache.prEnd = uint16(PriceRange.tickToPr(position.tickUpper));

        // console.log("dCache.prStart : ", dCache.prStart, "  dCache.end : ", dCache.prStart);
        // TradeMath.printInt("position.tickLower : ", position.tickLower);
        // TradeMath.printInt("position.tickUpper : ", position.tickUpper);

        dCache.tickLower = position.tickLower;
        // uint256 amount0;
        // uint256 amount1;
        // Update if liquidity > 0
        if (position.priceMap.length > 0){
            dCache.entryPriceSlot = position.priceMap[0];
            for(uint16 prLoop = dCache.prStart; prLoop < dCache.prEnd; prLoop++){
                if (dCache.curPriceSlot < 1 || PriceRange.isLeftCross(prLoop)){ 
                    uint256 _ps = PriceRange.prToPs(prLoop);
                    dCache.entryTimeSlot = position.timeMap[dCache.prId];
                    dCache.curTimeSlot = IRoxPerpPool(perpPool).timeSlots(_ps);
                    dCache.entryPriceSlot = position.priceMap[dCache.prId];
                    dCache.curPriceSlot = IRoxPerpPool(perpPool).priceSlot(_ps);
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
                    // console.log( "Entry Price: ",dCache.entryPrice,"  Curr Price: ", dCache.curPrice);
                    dCache.liquidity = TradeMath.liqTrans(liquidityDelta, dCache.entryPrice, dCache.curPrice);
                    // console.log("entryPrice", dCache.entryPrice, "   curPrice : ", dCache.curPrice);
                    // console.log("dCache.liquidity", dCache.liquidity, "   liquidityDelta : ", liquidityDelta);
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
            // console.log("dCache.prStart : ", dCache.prStart, "  dCache.end : ", dCache.prEnd);
            dCache.prStart = uint16(PriceRange.tickToPr(position.tickLower));
            dCache.prEnd = uint16(PriceRange.tickToPr(position.tickUpper));
            // Update if liquidity > 0
            dCache.entryPriceSlot = position.priceMap[0];
            for(uint16 prLoop = dCache.prStart; prLoop < dCache.prEnd; prLoop++){
                if (dCache.curPriceSlot < 1 || PriceRange.isLeftCross(prLoop)){ 
                    uint256 _ps = PriceRange.prToPs(prLoop);
                    dCache.entryTimeSlot = position.timeMap[dCache.prId];
                    dCache.curTimeSlot = IRoxPerpPool(perpPool).timeSlots(_ps);
                    dCache.entryPriceSlot = position.priceMap[dCache.prId];
                    dCache.curPriceSlot = IRoxPerpPool(perpPool).priceSlot(_ps);
                    dCache.prId += 1;
                }
                dCache.entryPrice = PriceRange.priceInPs(dCache.entryPriceSlot, prLoop);
                dCache.entryTime = PriceRange.prTime(dCache.entryTimeSlot, prLoop);
                dCache.curTime = PriceRange.prTime(dCache.curTimeSlot, prLoop);
                
                if (dCache.curTime > dCache.entryTime && dCache.entryPrice > 0){
                    PriceRange.FeeInfo memory prEntry = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeIndex(prLoop, dCache.entryTime));
                    PriceRange.FeeInfo memory prCur = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeIndex(prLoop, dCache.curTime));
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