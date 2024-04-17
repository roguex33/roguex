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
import "./libraries/Oracle.sol";
import "./NoDelegateCall.sol";



contract RoxPosnPool is IRoxPosnPool, NoDelegateCall {
    using LowGasSafeMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using PriceRange for uint256[370];
    using PriceRange for mapping(uint256 => PriceRange.FeeInfo);
    using Oracle for Oracle.Observation[65535];

    Oracle.Observation[65535] public observations;//o


    // price = realLiq / supLiq 
    // position realLiq = entrySupLiq * latestPrice
    //                  = entryRealLiq / entryPrice * latestPrice
    // supLiq = realLiq / price
    mapping(bytes32 => RoxPosition.Position) public roxPositions;
    mapping(bytes32 => uint256) public override lpLocktime;

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
    
    uint256 public override uncollect0;
    uint256 public override uncollect1;
    // uint256 public spot0fee;
    // uint256 public spot1fee;
    // uint256 public perp0fee;
    // uint256 public perp1fee;
    event BurnLp(address owner, uint256 liquidity, uint256 liquidityDelta);
    event LockLp(address owner, uint256 lockTime);

    modifier onlySpotPool() {
        require(msg.sender == spotPool, "os");
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
        require(msg.sender == perpPool, "xpp"); 
        priceSlots.writePriceSlot(_psId, _priceSlot);
    }


    function updatePerpFee(
        uint256 curTime,
        uint16 pr,
        uint256 price,
        uint256 liq,
        uint256 feeDelta,
        bool long0) external override {
        require(msg.sender == perpPool, "xpp");

        // long0 ? perp0fee += feeDelta : perp1fee += feeDelta;
        // long0 ? uncollect0 += feeDelta : uncollect1 += feeDelta;

        uint256 ps = PriceRange.prToPs(pr);
        uint256 slotCache = timeSlots[ps];

        prs.updatePerpFee(
            PriceRange.prTime(slotCache, pr),
            curTime,
            pr,
            price,
            liq,
            feeDelta,
            long0);

        timeSlots[ps] = PriceRange.updateU32Slot(slotCache, pr, curTime);
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
        // zeroForOne ? spot0fee += feeToken : spot1fee += feeToken;
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

    function burnLp(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDelta
    ) public {
        address owner = msg.sender;
        bytes32 _key = PositionKey.compute(
                        owner,
                        tickLower,
                        tickUpper
                    );
        // RoxPosition.Position memory position = self[_key];

        RoxPosition.Position storage position = roxPositions[_key];
        require(position.liquidity >= liquidityDelta, "bol");
        emit BurnLp(owner, position.liquidity, liquidityDelta);
        position.liquidity = position.liquidity - liquidityDelta;
    }

    function lockLp(
        int24 tickLower,
        int24 tickUpper,
        uint256 releaseTime
    ) public {
        address owner = msg.sender;
        bytes32 _key = PositionKey.compute(
                        owner,
                        tickLower,
                        tickUpper
                    );
        // RoxPosition.Position memory position = self[_key];

        RoxPosition.Position storage position = roxPositions[_key];
        require(position.liquidity >= 0, "bol");
        require(releaseTime > block.timestamp, "tahead");
        emit LockLp(owner, releaseTime);
        lpLocktime[_key] = releaseTime;
    }



    function increaseLiquidity(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDelta
        ) public override onlySpotPool{
        require(tickUpper > tickLower && tickUpper - tickLower < 240000, "Liquidity Range Too Large");
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
                    uint256 _newPrice = updatePositionEntryPrice(
                                        position.liquidity,
                                        dCache.entryPrice,
                                        liquidityDelta,
                                        dCache.curPrice);
                    dCache.entryPriceSlot = PriceRange.updateU32Slot(
                                dCache.entryPriceSlot, 
                                prLoop,
                                _newPrice
                                );
                }
                if (prLoop >= dCache.prEnd -1 || PriceRange.isRightCross(prLoop)){ 
                    position.priceMap[dCache.prId] = dCache.entryPriceSlot;
                    dCache.curPriceSlot = 0;
                    dCache.prId += 1;
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

        uncollect0 = uncollect0 > amount0 ? uncollect0.sub(amount0) : 0;
        uncollect1 = uncollect1 > amount1 ? uncollect1.sub(amount1) : 0;


        // require(spot0fee >= position.spotFeeOwed0, "sp0 fee");
        // require(spot1fee >= position.spotFeeOwed1, "sp1 fee");
        // spot0fee -= position.spotFeeOwed0;
        // spot1fee -= position.spotFeeOwed1;
        // require(perp0fee >= position.perpFeeOwed0, "pp0 fee");
        // require(perp1fee >= position.perpFeeOwed1, "pp1 fee");
        // perp0fee -= position.perpFeeOwed0;
        // perp1fee -= position.perpFeeOwed1;

        amount0 += position.spotFeeOwed0;
        amount1 += position.spotFeeOwed1;
       
        amount0 += position.perpFeeOwed0;
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
        require(position.liquidity >= liquidityDelta, "bol");

        if (lpLocktime[_key] > 0)
            require(block.timestamp > lpLocktime[_key], "lp Locked");

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
                    uint256 entrySupLiq = FullMath.mulDiv(position.liquidity, PriceRange.PRP_PREC, dCache.entryPrice);
                    position.spotFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee0X128, prCur.spotFee0X128);
                    position.spotFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee1X128, prCur.spotFee1X128);
                    position.perpFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee0X128, prCur.perpFee0X128);
                    position.perpFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee1X128, prCur.perpFee1X128);           
                }

                //TODO: combine burn to save gas
                // if (dCache.entryPrice != dCache.curPrice || prs == endPr){
                {
                    dCache.liquidity = liqTrans(liquidityDelta, dCache.entryPrice, dCache.curPrice);
                    liqDelta[i] = dCache.liquidity;
                    // liqRatio[i+1] = dCache.curPrice;
                    i += 1;

                    (uint256 a0cache, uint256 a1cache) = RoxPosition.getRangeToken(dCache.liquidity, 
                            dCache.tickLower, (dCache.tickLower+=600), tick, sqrtPriceX96, false);
                    amount0 += a0cache;
                    amount1 += a1cache;
                }
            }
            position.tokensOwed0 += uint128(amount0);
            position.tokensOwed1 += uint128(amount1);
            uncollect0 += amount0;
            uncollect1 += amount1;
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
                    dCache.liquidity = liqTrans(liquidityDelta, dCache.entryPrice, dCache.curPrice);
                    (uint256 a0cache, uint256 a1cache) = RoxPosition.getRangeToken(dCache.liquidity, 
                            dCache.tickLower, (dCache.tickLower += 600), tick, sqrtPriceX96, false);
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



    function updatePositionEntryPrice(
        uint256 entryLiq,
        uint256 entryPrice,
        uint256 newLiq,
        uint256 curPrice
    ) internal pure returns (uint256) {
        // entryLiqNow + newRealLiq = (positinLiq + newRealLiq) / avePrice * newPrice
        // positinLiq / entryPrice * newPrice + newRealLiq = (positinLiq + newRealLiq) * newPrice / avePrice
        // avePrice = (positinLiq + newRealLiq) * newPrice / (positinLiq * newPrice / entryPrice  + newRealLiq)
        if (curPrice == entryPrice)
            return curPrice;
        if (entryPrice < 1)
            return 0;
        
        uint256 positionRealLiq = FullMath.mulDiv(entryLiq, curPrice, entryPrice);
        uint256 _newPrice = FullMath.mulDiv(entryLiq + newLiq, curPrice, positionRealLiq + newLiq) + 1;//round up
        return _newPrice;
    }



    function liqTrans(
        uint128 entryLiq,
        uint256 entryPrice,
        uint256 curPrice
    ) internal pure returns (uint128) {
        if (entryPrice < 1)
            return 0;
        if (entryPrice == curPrice)
            return entryLiq;
        return
            uint128(
                FullMath.mulDiv(
                    uint256(entryLiq),
                    uint256(curPrice),
                    uint256(entryPrice)
                )
            );
    }


    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    function observe(
        uint32[] calldata secondsAgos,
        int24 tick,
        uint16 observationIndex,
        uint128 liquidity,
        uint16 observationCardinality
    )
        external
        view
        override
        noDelegateCall
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    {
        return
            observations.observe(
                _blockTimestamp(),
                secondsAgos,
                tick,
                observationIndex,
                liquidity,
                observationCardinality
            );
    }

    function initializeObserve( ) external onlySpotPool override returns (uint16 cardinality, uint16 cardinalityNext) {
        (cardinality, cardinalityNext) = observations.initialize(
            _blockTimestamp()
        );
    }

    function writeObserve(
        uint16 startObservationIndex,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity,
        uint16 startObservationCardinality,
        uint16 observationCardinalityNext
     ) external onlySpotPool override returns (uint16 observationIndex,uint16 observationCardinality)  {
            (
                observationIndex,
                observationCardinality
            ) = observations.write(
                    startObservationIndex,
                    blockTimestamp,
                    tick,
                    liquidity,
                    startObservationCardinality,
                    observationCardinalityNext
                );
     }

    function observeSingle(
            uint32 time,
            int24 tick,
            uint16 observationIndex,
            uint128 liquidity,
            uint16 observationCardinality
        ) external view override returns (
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128
        ) {

            (
                tickCumulative,
                secondsPerLiquidityCumulativeX128
            ) = observations.observeSingle(
                    time,
                    0,
                    tick,
                    observationIndex,
                    liquidity,
                    observationCardinality
                );
        }

}