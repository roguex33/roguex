// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "./interfaces/IRoxSpotPoolDeployer.sol";
import "./interfaces/IRoguexFactory.sol";
import "./interfaces/IRoxPerpPoolDeployer.sol";
import "./interfaces/IRoxSpotPool.sol";
import "./interfaces/IRoxPerpPool.sol";
import "./interfaces/IERC20Minimal.sol";
import "./interfaces/IRoxPosnPool.sol";
import "./interfaces/IRoxPosnPoolDeployer.sol";

import "./libraries/PositionKey.sol";

import "./interfaces/IRoxUtils.sol";

import "./libraries/TransferHelper.sol";
import "./libraries/EnumerableValues.sol";
import "./libraries/TradeData.sol";
import "./libraries/TradeMath.sol";
import "./libraries/RoxPosition.sol";

import "./libraries/LowGasSafeMath.sol";
import "./libraries/SafeCast.sol";
import "./libraries/Tick.sol";
import "./libraries/TickBitmap.sol";

import "./libraries/FullMath.sol";
import "./libraries/FixedPoint128.sol";
import "./libraries/TickMath.sol";
import "./libraries/LiquidityMath.sol";
import "./libraries/SqrtPriceMath.sol";
import "./libraries/SwapMath.sol";
import './libraries/PriceRange.sol';
import './libraries/PosRange.sol';

import "hardhat/console.sol";

contract RoxPosnPool is IRoxPosnPool {
    using SafeMath for uint256;
    using SafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;


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

        dCache.prStart = uint16(TradeMath.tickToPr(position.tickLower));
        dCache.prEnd = uint16(TradeMath.tickToPr(position.tickUpper));
        dCache.tickLower = position.tickLower;
        // RoxPosition.checkTick(position.tickLower, position.tickUpper);

        // Update if liquidity > 0
        if (position.liquidity > 0 && position.priceMap.length > 0){
            dCache.entryPriceSlot = position.priceMap[0];
            for(uint16 prLoop = dCache.prStart; prLoop < dCache.prEnd; prLoop++){
                if (dCache.curPriceSlot < 1 || TradeMath.isLeftCross(prLoop)){ 
                    dCache.entryTimeSlot = position.timeMap[dCache.prId];
                    dCache.curTimeSlot = IRoxPerpPool(perpPool).prUpdTime(prLoop/12);
                    dCache.entryPriceSlot = position.priceMap[dCache.prId];
                    dCache.curPriceSlot = IRoxPerpPool(perpPool).priceSlot(TradeMath.prToPs(prLoop));
                    dCache.prId += 1;
                }
                dCache.cPrice = TradeMath.priceInPs(dCache.entryPriceSlot, prLoop);
                dCache.pPrice = TradeMath.priceInPs(dCache.curPriceSlot, prLoop);
                //TODO: combine 0 & 1 to save gas
                dCache.entryTime = uint32(PriceRange.prTime(dCache.entryTimeSlot, prLoop));
                dCache.curTime = uint32(PriceRange.prTime(dCache.curTimeSlot, prLoop));

                //fee settle
                if (dCache.cPrice > 0) {
                    PriceRange.Info memory prEntry = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeId(prLoop, dCache.entryTime));
                    PriceRange.Info memory prCur = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeId(prLoop, dCache.curTime));
                    uint256 entrySupLiq = uint256(position.liquidity) * 10000 / dCache.cPrice;
                    position.spotFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee0X128, prCur.spotFee0X128);
                    position.spotFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee1X128, prCur.spotFee1X128);
                    position.perpFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee0X128, prCur.perpFee0X128);
                    position.perpFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee1X128, prCur.perpFee1X128);           
                }

                {
                    dCache.entryPriceSlot = TradeMath.updatePs(dCache.entryPriceSlot, prLoop,
                                TradeMath.weightAve(
                                    position.liquidity,
                                    dCache.cPrice,
                                    liquidityDelta,
                                    dCache.pPrice
                                ) );
                }
                if (prLoop == dCache.prEnd || TradeMath.isRightCross(prLoop)){ 
                    position.priceMap[dCache.prId] = dCache.entryPriceSlot;
                }
            }

        }
        else{
            position.priceMap = IRoxPerpPool(perpPool).encodePriceSlots(dCache.prStart, dCache.prEnd);
        }

        position.timeMap = IRoxPerpPool(perpPool).encodeTimeSlots(dCache.prStart, dCache.prEnd);
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
    ) public override onlySpotPool {
        RoxPosition.Position memory position = roxPositions[_key];
        UpdCache memory dCache;
        if (position.owner == address(0))
            return ;

        if (position.liquidity < 1 || position.priceMap.length < 1)
            return ;
            
        dCache.prStart = uint16(TradeMath.tickToPr(position.tickLower));
        dCache.prEnd = uint16(TradeMath.tickToPr(position.tickUpper));
        // Update if liquidity > 0
        dCache.entryPriceSlot = position.priceMap[0];
        for(uint16 prLoop = dCache.prStart; prLoop < dCache.prEnd; prLoop++){
            if (dCache.curPriceSlot < 1 || TradeMath.isLeftCross(prLoop)){ 
                dCache.entryTimeSlot = position.timeMap[dCache.prId];
                dCache.curTimeSlot = IRoxPerpPool(perpPool).prUpdTime(prLoop/12);
                dCache.entryPriceSlot = position.priceMap[dCache.prId];
                dCache.curPriceSlot = IRoxPerpPool(perpPool).priceSlot(TradeMath.prToPs(prLoop));
                dCache.prId += 1;
            }
            dCache.cPrice = TradeMath.priceInPs(dCache.entryPriceSlot, prLoop);
            //TODO: combine 0 & 1 to save gas
            dCache.entryTime = uint32(PriceRange.prTime(dCache.entryTimeSlot, prLoop));
            dCache.curTime = uint32(PriceRange.prTime(dCache.curTimeSlot, prLoop));

            //fee settle
            if (dCache.cPrice > 0) {
                PriceRange.Info memory prEntry = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeId(prLoop, dCache.entryTime));
                PriceRange.Info memory prCur = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeId(prLoop, dCache.curTime));
                uint256 entrySupLiq = uint256(position.liquidity) * 10000 / dCache.cPrice;
                position.spotFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee0X128, prCur.spotFee0X128);
                position.spotFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee1X128, prCur.spotFee1X128);
                position.perpFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee0X128, prCur.perpFee0X128);
                position.perpFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee1X128, prCur.perpFee1X128);           
            }
        } 

        // Update to latesr time slots
        position.timeMap = IRoxPerpPool(perpPool).encodeTimeSlots(dCache.prStart, dCache.prEnd);
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

        uint32 pPrice;
        uint32 cPrice;
        uint32 entryTime;
        uint32 curTime;
    }


    function decreaseLiquidity(
        bytes32 _key,
        uint128 liquidityDelta,
        int24 tick,
        uint160 sqrtPriceX96
    ) external override onlySpotPool returns (uint32[] memory liqRatio, uint256 amount0, uint256 amount1){

        RoxPosition.Position memory position = roxPositions[_key];
        RoxPosition.UpdCache memory dCache;
        // console.log("position.liquidity", position.liquidity);
        // console.log("liquidityDelta    ", liquidityDelta);
        require(position.liquidity >= liquidityDelta, "out of liq burn");

        // // uint128 positionLiquidity_p = params.liquidity;// * price
        dCache.prStart = uint16(TradeMath.tickToPr(position.tickLower));
        dCache.prEnd = uint16(TradeMath.tickToPr(position.tickUpper));

        // console.log("dCache.prStart : ", dCache.prStart, "  dCache.end : ", dCache.prStart);
        // TradeMath.printInt("position.tickLower : ", position.tickLower);
        // TradeMath.printInt("position.tickUpper : ", position.tickUpper);

        dCache.tickLower = position.tickLower;
        liqRatio = new uint32[]( uint(position.tickUpper - position.tickLower) / 300);
        // uint256 amount0;
        // uint256 amount1;
        // Update if liquidity > 0
        if (position.priceMap.length > 0){
            dCache.entryPriceSlot = position.priceMap[0];
            uint i = 0;
            for(uint16 prLoop = dCache.prStart; prLoop < dCache.prEnd; prLoop++){
                if (dCache.curPriceSlot < 1 || TradeMath.isLeftCross(prLoop)){ 
                    dCache.entryTimeSlot = position.timeMap[dCache.prId];
                    dCache.curTimeSlot = IRoxPerpPool(perpPool).prUpdTime(prLoop/12);
                    dCache.entryPriceSlot = position.priceMap[dCache.prId];
                    dCache.curPriceSlot = IRoxPerpPool(perpPool).priceSlot(TradeMath.prToPs(prLoop));
                    dCache.prId += 1;
                }
                dCache.cPrice = TradeMath.priceInPs(dCache.entryPriceSlot, prLoop);
                dCache.pPrice = TradeMath.priceInPs(dCache.curPriceSlot, prLoop);
                //TODO: combine 0 & 1 to save gas
                dCache.entryTime = uint32(PriceRange.prTime(dCache.entryTimeSlot, prLoop));
                dCache.curTime = uint32(PriceRange.prTime(dCache.curTimeSlot, prLoop));

                //fee settle
                if (dCache.cPrice > 0) {
                    PriceRange.Info memory prEntry = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeId(prLoop, dCache.entryTime));
                    PriceRange.Info memory prCur = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeId(prLoop, dCache.curTime));
                    uint256 entrySupLiq = uint256(position.liquidity) * 10000 / dCache.cPrice;
                    position.spotFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee0X128, prCur.spotFee0X128);
                    position.spotFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee1X128, prCur.spotFee1X128);
                    position.perpFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee0X128, prCur.perpFee0X128);
                    position.perpFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee1X128, prCur.perpFee1X128);           
                }

                 //TODO: combine burn to save gas
                // if (dCache.cPrice != dCache.pPrice || prs == endPr){
                {
                    // console.log( "Entry Price: ",dCache.cPrice,"  Curr Price: ", dCache.pPrice);
                    dCache.liquidity = TradeMath.liqTrans(liquidityDelta, dCache.cPrice, dCache.pPrice);
                    liqRatio[i] = dCache.cPrice;
                    liqRatio[i+1] = dCache.pPrice;
                    i += 2;

                    // console.log("cPrice", dCache.cPrice, "   pPrice : ", dCache.pPrice);
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
        position.timeMap = IRoxPerpPool(perpPool).encodeTimeSlots(dCache.prStart, dCache.prEnd);
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
        RoxPosition.UpdCache memory dCache;
        // console.log("position.liquidity", position.liquidity);
        // console.log("liquidityDelta    ", liquidityDelta);
        require(position.liquidity >= liquidityDelta, "out of liq burn");

        // // uint128 positionLiquidity_p = params.liquidity;// * price
        dCache.prStart = uint16(TradeMath.tickToPr(position.tickLower));
        dCache.prEnd = uint16(TradeMath.tickToPr(position.tickUpper));

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
                if (dCache.curPriceSlot < 1 || TradeMath.isLeftCross(prLoop)){ 
                    dCache.entryTimeSlot = position.timeMap[dCache.prId];
                    dCache.curTimeSlot = IRoxPerpPool(perpPool).prUpdTime(prLoop/12);
                    dCache.entryPriceSlot = position.priceMap[dCache.prId];
                    dCache.curPriceSlot = IRoxPerpPool(perpPool).priceSlot(TradeMath.prToPs(prLoop));
                    dCache.prId += 1;
                }
                dCache.cPrice = TradeMath.priceInPs(dCache.entryPriceSlot, prLoop);
                dCache.pPrice = TradeMath.priceInPs(dCache.curPriceSlot, prLoop);
                //TODO: combine 0 & 1 to save gas
                dCache.entryTime = uint32(PriceRange.prTime(dCache.entryTimeSlot, prLoop));
                dCache.curTime = uint32(PriceRange.prTime(dCache.curTimeSlot, prLoop));

                 //TODO: combine burn to save gas
                // if (dCache.cPrice != dCache.pPrice || prs == endPr){
                {
                    // console.log( "Entry Price: ",dCache.cPrice,"  Curr Price: ", dCache.pPrice);
                    dCache.liquidity = TradeMath.liqTrans(liquidityDelta, dCache.cPrice, dCache.pPrice);
                    // console.log("cPrice", dCache.cPrice, "   pPrice : ", dCache.pPrice);
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
        
        UpdCache memory dCache;
        if (position.owner == address(0))
            return (0,0,0,0,0,0);

        if (position.liquidity < 1 || position.priceMap.length < 1)
            return (0,0,0,0,0,0);
            

        dCache.prStart = uint16(TradeMath.tickToPr(position.tickLower));
        dCache.prEnd = uint16(TradeMath.tickToPr(position.tickUpper));
        // Update if liquidity > 0
        dCache.entryPriceSlot = position.priceMap[0];
        
        // console.log("dCache.prStart : ", dCache.prStart, "  dCache.end : ", dCache.prEnd);

        for(uint16 prLoop = dCache.prStart; prLoop < dCache.prEnd; prLoop++){

            if (dCache.curPriceSlot < 1 || TradeMath.isLeftCross(prLoop)){ 
                dCache.entryTimeSlot = position.timeMap[dCache.prId];
                dCache.curTimeSlot = IRoxPerpPool(perpPool).prUpdTime(prLoop/12);
                dCache.entryPriceSlot = position.priceMap[dCache.prId];
                dCache.curPriceSlot = IRoxPerpPool(perpPool).priceSlot(TradeMath.prToPs(prLoop));
                dCache.prId += 1;
            }


            dCache.cPrice = TradeMath.priceInPs(dCache.entryPriceSlot, prLoop);
            //TODO: combine 0 & 1 to save gas
            dCache.entryTime = uint32(PriceRange.prTime(dCache.entryTimeSlot, prLoop));
            dCache.curTime = uint32(PriceRange.prTime(dCache.curTimeSlot, prLoop));
            

            //fee settle
            if (dCache.cPrice > 0) {
                PriceRange.Info memory prEntry = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeId(prLoop, dCache.entryTime));
                PriceRange.Info memory prCur = IRoxPerpPool(perpPool).prInfo(PriceRange.prTimeId(prLoop, dCache.curTime));        
                uint256 entrySupLiq = uint256(position.liquidity) * 10000 / dCache.cPrice;
                spotFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee0X128, prCur.spotFee0X128);
                spotFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee1X128, prCur.spotFee1X128);
                perpFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee0X128, prCur.perpFee0X128);
                perpFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee1X128, prCur.perpFee1X128);    
            }

        } 

        tokenOw0 += uint128(position.tokensOwed0);
        tokenOw1 += uint128(position.tokensOwed1);
        spotFeeOwed0 += position.spotFeeOwed0;
        spotFeeOwed1 += position.spotFeeOwed1;
        perpFeeOwed0 += position.perpFeeOwed0;
        perpFeeOwed1 += position.perpFeeOwed1;
    }


    // function _updateFee(
    //     bytes32 _key
    // ) private {
    //     RoxPosition.Position memory position = positions[_key];
        
    //     UpdCache memory dCache;
    //     if (position.owner == address(0))
    //         return ;

    //     if (position.liquidity < 1 || position.priceMap.length < 1)
    //         return ;
            
    //     dCache.prStart = uint16(TradeMath.tickToPr(position.tickLower));
    //     dCache.prEnd = uint16(TradeMath.tickToPr(position.tickUpper));
    //     // Update if liquidity > 0
    //     dCache.entryPriceSlot = position.priceMap[0];
    //     for(uint16 prLoop = dCache.prStart; prLoop < dCache.prEnd; prLoop++){
    //         if (dCache.curPriceSlot < 1 || TradeMath.isLeftCross(prLoop)){ 
    //             dCache.entryTimeSlot = position.timeMap[dCache.prId];
    //             dCache.curTimeSlot = perpPool.prUpdTime(prLoop/12);
    //             dCache.entryPriceSlot = position.priceMap[dCache.prId];
    //             dCache.prId += 1;
    //         }
    //         dCache.cPrice = TradeMath.priceInPs(dCache.entryPriceSlot, prLoop);
    //         //TODO: combine 0 & 1 to save gas
    //         dCache.entryTime = uint32(PriceRange.prTime(dCache.entryTimeSlot, prLoop));
    //         dCache.curTime = uint32(PriceRange.prTime(dCache.curTimeSlot, prLoop));

    //         //fee settle
    //         if (dCache.cPrice > 0) {
    //             PriceRange.Info memory prEntry = perpPool.prInfo(PriceRange.prTimeId(prLoop, dCache.entryTime));
    //             PriceRange.Info memory prCur = perpPool.prInfo(PriceRange.prTimeId(prLoop, dCache.curTime));
    //             uint256 entrySupLiq = uint256(position.liquidity) * 10000 / dCache.cPrice;
    //             position.spotFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee0X128, prCur.spotFee0X128);
    //             position.spotFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee1X128, prCur.spotFee1X128);
    //             position.perpFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee0X128, prCur.perpFee0X128);
    //             position.perpFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee1X128, prCur.perpFee1X128);           
    //         }
    //     } 

    //     // Update to latesr time slots
    //     position.timeMap = perpPool.encodeTimeSlots(dCache.prStart, dCache.prEnd);
    //     positions[_key] = position;
    // }

    // function _decreaseLiquidity(
    //     bytes32 _key,
    //     uint128 liquidityDelta
    // ) private returns (uint256 amount0, uint256 amount1){
    //     RoxPosition.Position memory position = positions[_key];
    //     UpdCache memory dCache;

    //     require(position.liquidity >= liquidityDelta, "out of liq burn");

    //     // // uint128 positionLiquidity_p = params.liquidity;// * price
    //     dCache.prStart = uint16(TradeMath.tickToPr(position.tickLower));
    //     dCache.prEnd = uint16(TradeMath.tickToPr(position.tickUpper));
    //     dCache.tickLower = position.tickLower;

    //     (uint160 curSqrtPrice, int24 tickCur , , , , , ) = spotPool.slot0();



    //     // Update if liquidity > 0
    //     if (position.priceMap.length > 0){
    //         dCache.entryPriceSlot = position.priceMap[0];
    //         for(uint16 prLoop = dCache.prStart; prLoop < dCache.prEnd; prLoop++){
    //             if (dCache.curPriceSlot < 1 || TradeMath.isLeftCross(prLoop)){ 
    //                 dCache.entryTimeSlot = position.timeMap[dCache.prId];
    //                 dCache.curTimeSlot = perpPool.prUpdTime(prLoop/12);
    //                 dCache.entryPriceSlot = position.priceMap[dCache.prId];
    //                 dCache.curPriceSlot = perpPool.priceSlot(TradeMath.prToPs(prLoop));
    //                 dCache.prId += 1;
    //             }
    //             dCache.cPrice = TradeMath.priceInPs(dCache.entryPriceSlot, prLoop);
    //             dCache.pPrice = TradeMath.priceInPs(dCache.curPriceSlot, prLoop);
    //             //TODO: combine 0 & 1 to save gas
    //             dCache.entryTime = uint32(PriceRange.prTime(dCache.entryTimeSlot, prLoop));
    //             dCache.curTime = uint32(PriceRange.prTime(dCache.curTimeSlot, prLoop));

    //             //fee settle
    //             if (dCache.cPrice > 0) {
    //                 PriceRange.Info memory prEntry = perpPool.prInfo(PriceRange.prTimeId(prLoop, dCache.entryTime));
    //                 PriceRange.Info memory prCur = perpPool.prInfo(PriceRange.prTimeId(prLoop, dCache.curTime));
    //                 uint256 entrySupLiq = uint256(position.liquidity) * 10000 / dCache.cPrice;
    //                 position.spotFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee0X128, prCur.spotFee0X128);
    //                 position.spotFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee1X128, prCur.spotFee1X128);
    //                 position.perpFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee0X128, prCur.perpFee0X128);
    //                 position.perpFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee1X128, prCur.perpFee1X128);           
    //             }

    //              //TODO: combine burn to save gas
    //             // if (dCache.cPrice != dCache.pPrice || prs == endPr){
    //             {
    //                 // console.log( "Entry Price: ",dCache.cPrice,"  Curr Price: ", dCache.pPrice);
    //                 dCache.liquidity = TradeMath.liqTrans(position.liquidity, dCache.cPrice, dCache.pPrice);

    //                 //Update liquidity in spot pool
    //                 spotPool.updatePnl(dCache.tickLower, dCache.tickLower + 600, tickCur, int128(dCache.liquidity));
                    
    //                 // TODO: save sqrtPrice from tick to save gas
    //                 (dCache.a0cache, dCache.a1cache) = RoxPosition.getRangeToken(dCache.liquidity, 
    //                     dCache.tickLower, (dCache.tickLower += 600), tickCur, curSqrtPrice);
    //                 // console.log("dC.liquidity : ", dCache.liquidity);
    //                 // console.log("re.liquidity : ", liquidity);
    //                 // TradeMath.printInt("PrLoop StrTick:", TradeMath.prToTick(prLoop));
    //                 // TradeMath.printInt("PrLoop EndTick:", TradeMath.prToTick(prLoop+1));
    //                 amount0 += dCache.a0cache;
    //                 amount1 += dCache.a1cache;
    //             }

    //             // Do not need to update price in decrease liquidity
    //             // {
    //             //     dCache.entryPriceSlot = TradeMath.updatePs(dCache.entryPriceSlot, prLoop,
    //             //                 TradeMath.weightAve(
    //             //                     position.liquidity,
    //             //                     dCache.cPrice,
    //             //                     dCache.liquidity,
    //             //                     dCache.pPrice
    //             //                 ) );
    //             // }
    //             // if (prLoop == dCache.prEnd || TradeMath.isRightCross(prLoop)){ 
    //             //     position.priceMap[dCache.prId] = dCache.entryPriceSlot;
    //             // }
    //         }

    //         spotPool.updateRec(amount0, amount1, true);
    //         position.tokensOwed0 += uint128(amount0);
    //         position.tokensOwed1 += uint128(amount1);
    //     }

    //     // else{
    //     //     position.priceMap = perpPool.encodePriceSlots(dCache.prStart, dCache.prEnd);
    //     // }

    //     position.timeMap = perpPool.encodeTimeSlots(dCache.prStart, dCache.prEnd);
    //     position.liquidity = position.liquidity - dCache.liquidity;

    //     positions[_key] = position;
    // }

    // function _increaseLiquidity(
    //     RoxPosition.Position memory position,
    //     uint128 liquidityDelta
    // ) private view returns (RoxPosition.Position memory, uint256 , uint256 ){
        
    //     uint256 amount0;
    //     uint256 amount1;
    //     UpdCache memory dCache;

    //     dCache.prStart = uint16(TradeMath.tickToPr(position.tickLower));
    //     dCache.prEnd = uint16(TradeMath.tickToPr(position.tickUpper));
    //     dCache.tickLower = position.tickLower;

    //     (uint160 curSqrtPrice, int24 tickCur , , , , , ) = spotPool.slot0();
    //     // if (dCache.cPrice != dCache.pPrice || prs == endPr){
    //     {
    //         // console.log( "Entry Price: ",dCache.cPrice,"  Curr Price: ", dCache.pPrice);
    //         //Update liquidity in spot pool
    //         spotPool.updatePnl(position.tickLower, position.tickUpper, tickCur, int128(liquidityDelta));
            
    //         // TODO: save sqrtPrice from tick to save gas
    //         (amount0, amount1) = RoxPosition.getRangeToken(liquidityDelta, 
    //             position.tickLower, position.tickUpper, tickCur, curSqrtPrice);
    //     }

    //     // Update if liquidity > 0
    //     if (position.liquidity > 0 && position.priceMap.length > 0){
    //         dCache.entryPriceSlot = position.priceMap[0];
    //         for(uint16 prLoop = dCache.prStart; prLoop < dCache.prEnd; prLoop++){
    //             if (dCache.curPriceSlot < 1 || TradeMath.isLeftCross(prLoop)){ 
    //                 dCache.entryTimeSlot = position.timeMap[dCache.prId];
    //                 dCache.curTimeSlot = perpPool.prUpdTime(prLoop/12);
    //                 dCache.entryPriceSlot = position.priceMap[dCache.prId];
    //                 dCache.curPriceSlot = perpPool.priceSlot(TradeMath.prToPs(prLoop));
    //                 dCache.prId += 1;
    //             }
    //             dCache.cPrice = TradeMath.priceInPs(dCache.entryPriceSlot, prLoop);
    //             dCache.pPrice = TradeMath.priceInPs(dCache.curPriceSlot, prLoop);
    //             //TODO: combine 0 & 1 to save gas
    //             dCache.entryTime = uint32(PriceRange.prTime(dCache.entryTimeSlot, prLoop));
    //             dCache.curTime = uint32(PriceRange.prTime(dCache.curTimeSlot, prLoop));

    //             //fee settle
    //             if (dCache.cPrice > 0) {
    //                 PriceRange.Info memory prEntry = perpPool.prInfo(PriceRange.prTimeId(prLoop, dCache.entryTime));
    //                 PriceRange.Info memory prCur = perpPool.prInfo(PriceRange.prTimeId(prLoop, dCache.curTime));
    //                 uint256 entrySupLiq = uint256(position.liquidity) * 10000 / dCache.cPrice;
    //                 position.spotFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee0X128, prCur.spotFee0X128);
    //                 position.spotFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee1X128, prCur.spotFee1X128);
    //                 position.perpFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee0X128, prCur.perpFee0X128);
    //                 position.perpFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee1X128, prCur.perpFee1X128);           
    //             }

    //             {
    //                 dCache.entryPriceSlot = TradeMath.updatePs(dCache.entryPriceSlot, prLoop,
    //                             TradeMath.weightAve(
    //                                 position.liquidity,
    //                                 dCache.cPrice,
    //                                 dCache.liquidity,
    //                                 dCache.pPrice
    //                             ) );
    //             }
    //             if (prLoop == dCache.prEnd || TradeMath.isRightCross(prLoop)){ 
    //                 position.priceMap[dCache.prId] = dCache.entryPriceSlot;
    //             }
    //         }

    //         spotPool.updateRec(amount0, amount1, true);
    //         position.tokensOwed0 += uint128(amount0);
    //         position.tokensOwed1 += uint128(amount1);
    //     }
    //     else{
    //         position.priceMap = perpPool.encodePriceSlots(dCache.prStart, dCache.prEnd);
    //     }

    //     position.timeMap = perpPool.encodeTimeSlots(dCache.prStart, dCache.prEnd);
    //     position.liquidity = position.liquidity - dCache.liquidity;

    //     return (position, amount0, amount1);
    // }


}