// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./interfaces/IRoxSpotPool.sol";
import "./interfaces/IRoxPerpPool.sol";
import "./interfaces/IRoxPosnPool.sol";
import "./interfaces/IRoxUtils.sol";
import "./interfaces/IRoguexFactory.sol";
import "./interfaces/IPerpUtils.sol";
import "./libraries/TradeData.sol";
import "./libraries/TradeMath.sol";
import "./libraries/LowGasSafeMath.sol";
import "./libraries/SafeCast.sol";
import "./libraries/Tick.sol";
import "./libraries/TickBitmap.sol";
import "./libraries/LiquidityAmounts.sol";
import "./libraries/FullMath.sol";
import "./libraries/TickMath.sol";
import "./libraries/LiquidityMath.sol";
import "./libraries/SwapMath.sol";
import "./libraries/TickRange.sol";
import "./libraries/SqrtPriceMath.sol";


contract RoxUtils is IRoxUtils {
    uint256 internal constant Q96 = 0x1000000000000000000000000;
   
    using LowGasSafeMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;
    address public immutable factory;
    address public immutable override weth;
    address public liqManager;
    IPerpUtils public perpUtils;
    CloseFactor public cFt;
    PoolSetting public gSetting;
    
    mapping(address => PoolSetting) public poolSetting;

    struct PoolSetting{
        bool set;
        uint8 maxLeverage;
        uint16 spotThres;
        uint16 perpThres;
        uint16 setlThres;
        uint32 fdFeePerS;
        uint32 twapTime; 
        uint8 countMin;
    }
    
    struct CloseFactor{
        uint32 timeSecDynamic;
        uint16 kMax;
        uint8 powF;
        uint40 factor_s;
        uint160 factor_sf;
    }
    event ModifyPoolSetting(address pool, PoolSetting setting);
    event DeletePoolSetting(address pool);

    modifier onlyOwner() {
        require(msg.sender == IRoguexFactory(factory).owner(), "ow");
        _;
    }

    constructor(address _factory, address _weth){
        factory = _factory;
        weth = _weth;
        cFt = CloseFactor({
            timeSecDynamic : 1 hours,
            kMax: 320,
            powF : 2,
            factor_s : 1e4,
            factor_sf: 1e8
        });

        gSetting = PoolSetting({
            set : true,
            maxLeverage : 51,
            spotThres : 800,    // Default 80%, spot will be paused when perpResv / Liq.Total > spotThres 
            perpThres : 500,    // Default 50%, open position be paused when perpResv / Liq.Total > perpThres
            setlThres : 700,    // Default 70%,  when perpResv / Liq.Total > perpThres
            fdFeePerS : 6e3,
            twapTime : 30 seconds,
            countMin : 10 // unit: minutes
        } );
    }
    
    function updatePerpUtils( address _pU) external onlyOwner{
        perpUtils = IPerpUtils(_pU);
    }

    function pUtils() external override view returns (address){
        return address(perpUtils);
    }

    function setLiqManager(address _liqManager) external onlyOwner{
        liqManager = _liqManager;
    }

    function setGlobalSetting(
        uint8 _maxLeverage,
        uint16 _spotThres,
        uint16 _perpThres,
        uint16 _setlThres,
        uint32 _fdFeePerS,
        uint32 _twapTime,
        uint8 _countMin
    ) external onlyOwner{
        PoolSetting storage _gS = gSetting;
        _gS.set = true;
        require(_maxLeverage < 250);
        _gS.maxLeverage;

        require(_spotThres < 1001);
        _gS.spotThres = _spotThres;

        require(_perpThres < 1001);
        _gS.perpThres = _perpThres;

        require(_setlThres < 1001);
        _gS.setlThres = _setlThres;

        require(_fdFeePerS < 2e4);  // max fee per seconds. ( 1e4 * 3600 / 1e10 = 0.36% per hour)
        _gS.fdFeePerS = _fdFeePerS; //cal: size * fdFeePerS / 1e10 per sec
      
        require(_twapTime < 180); 
        _gS.twapTime = _twapTime; 

        require(_countMin < 30); 
        _gS.countMin = _countMin;   
    }

    function modifyPoolSetting(
        address _spotPool, 
        uint8 _maxLeverage,
        uint16 _spotThres,
        uint16 _perpThres,
        uint16 _setlThres,
        uint32 _fdFeePerS,
        uint32 _twapTime,
        uint8 _countMin,
        bool _del
        ) public override {
        require(msg.sender == IRoguexFactory(factory).spotOwner(_spotPool)
            || msg.sender == liqManager, "ow");
        
        IRoxPerpPool(IRoxSpotPool(_spotPool).roxPerpPool()).updateFundingRate();

        if (_del){
            delete poolSetting[_spotPool];
            emit DeletePoolSetting(_spotPool);

        }else{
            PoolSetting memory _gS = gSetting;
            require(_maxLeverage <= _gS.maxLeverage, "Max leverage");
            require(_spotThres <= _gS.spotThres, "Max spot threshold");
            require(_perpThres <= _gS.perpThres, "Max perp threshold");
            require(_setlThres <= _gS.setlThres, "Max settle threshold");
            require(_fdFeePerS <= _gS.fdFeePerS * 2, "max funding fee");
            require(_twapTime < 1200, "max twap time"); 
            require(_countMin < 20, "max close count frames"); 

            PoolSetting storage pSet = poolSetting[_spotPool];
            pSet.set = true;
            pSet.maxLeverage = _maxLeverage;
            pSet.spotThres = _spotThres;
            pSet.perpThres = _perpThres;
            pSet.setlThres = _setlThres;
            pSet.fdFeePerS = _fdFeePerS;
            pSet.twapTime = _twapTime; 
            pSet.countMin = _countMin; 

            emit ModifyPoolSetting(_spotPool, pSet);
        }

    }

    function setFactor(
            uint256 _kMax, 
            uint256 _powF, 
            uint16 _timeSecDynamic
            ) external onlyOwner{
        require(_kMax < 1001, "k max"); // ratio > k / 1000
        require(_powF < 5, "max pow");  // ATTENTION:  overflow when pow > 4
        uint256 fs = 100 ** _powF;
        cFt = CloseFactor({
            timeSecDynamic : uint32(_timeSecDynamic),
            kMax: uint16(_kMax),
            powF : uint8(_powF),
            factor_s : uint40(fs),
            factor_sf: uint160((fs)**_powF)
        });
    }

    function spotThres(address _spotPool) public view override returns(uint256){
        PoolSetting memory _pset = poolSetting[_spotPool];
        uint256 _gSpotThres = uint256(gSetting.spotThres);
        if (_pset.set){
            return _pset.spotThres < _gSpotThres ? _pset.spotThres : _gSpotThres;
        }else{
            return _gSpotThres;
        }
    }
    
    function perpThres(address _spotPool) public view override returns(uint256){
        PoolSetting memory _pset = poolSetting[_spotPool];
        uint256 _gPerpThres = uint256(gSetting.perpThres);
        if (_pset.set){
            return _pset.perpThres < _gPerpThres ? _pset.perpThres : _gPerpThres;
        }else{
            return _gPerpThres;
        }
    }

    function setlThres(address _spotPool) public view override returns(uint256){
        PoolSetting memory _pset = poolSetting[_spotPool];
        uint256 _gSetlThres = uint256(gSetting.setlThres);
        if (_pset.set){
            return _pset.spotThres < _gSetlThres ? _pset.spotThres : _gSetlThres;
        }else{
            return _gSetlThres;
        }
    }

    function fdFeePerS(address _spotPool) public view override returns(uint256){
        PoolSetting memory _pset = poolSetting[_spotPool];
        uint256 _gFdFeePerS = uint256(gSetting.fdFeePerS);
        if (_pset.set){
            return _pset.fdFeePerS < _gFdFeePerS ? _pset.fdFeePerS : _gFdFeePerS;
        }else{
            return _gFdFeePerS;
        }
    }    

    function maxLeverage(address _spotPool) public view override returns(uint256){
        PoolSetting memory _pset = poolSetting[_spotPool];
        uint256 _gMaxLeverage = uint256(gSetting.maxLeverage);
        if (_pset.set){
            return _pset.maxLeverage < _gMaxLeverage ? _pset.maxLeverage : _gMaxLeverage;
        }else{
            return _gMaxLeverage;
        }
    }

    function getSqrtTwapX96(
        address spotPool
    ) public view override returns (uint160 sqrtPriceX96) {
        PoolSetting memory _pset = poolSetting[spotPool];
        uint32 _twapsec = gSetting.twapTime;
        if (_pset.set && _pset.twapTime < _twapsec && _pset.twapTime > 0)
            _twapsec = _pset.twapTime;
        return getSqrtTwapX96Sec(spotPool, _twapsec);
    }

    function getTwapTickUnsafe(address _spotPool, uint32 _sec) public view override returns (int24 tick) {        
        IRoxSpotPool pool = IRoxSpotPool(_spotPool);
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = _sec; // from _sec ago 
        secondsAgos[1] = 0; // to now
        try pool.observe( secondsAgos ) returns (int56[] memory tickCumulatives, uint160[] memory )
        {
            tick = int24((tickCumulatives[1] - tickCumulatives[0]) / _sec);
        }
        catch (bytes memory ) {
            (, tick, , , , , ) = pool.slot0();
        }
    }



    function getSqrtTwapX96Sec(
        address spotPool,
        uint32 secAgo
    ) public view returns (uint160 sqrtPriceX96) {
        if (secAgo == 0) {
            (sqrtPriceX96, , , , , , ) = IRoxSpotPool(spotPool).slot0();
        } else {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = secAgo; // from [seconds] ago
            secondsAgos[1] = 0; // to now
            (int56[] memory tickCumulatives, ) = IRoxSpotPool(spotPool).observe(
                secondsAgos
            );
            sqrtPriceX96 = TickMath.getSqrtRatioAtTick(
                int24((tickCumulatives[1] - tickCumulatives[0]) / secAgo)
            );
        }
    }

    function getCountMin(address _spotPool) public view  returns(uint32){
        PoolSetting memory _pset = poolSetting[_spotPool];
        if (_pset.set){
            return uint32(_pset.countMin);
        }else{
            return uint32(gSetting.countMin);
        }
    }

    function gOpenPrice(
        address _perpPool,
        uint256 _sizeDelta,
        bool _long0,
        bool _isSizeCor
    ) public view override returns (uint160 openPrice, int24 openTick, uint160 twapPrice, uint24 rtnSpread) {        
        address _spotPool = IRoxPerpPool(_perpPool).spotPool();
        twapPrice = getSqrtTwapX96(_spotPool);

        bool unlocked;
        (openPrice, , , , , ,unlocked ) = IRoxSpotPool(_spotPool).slot0();
        if (msg.sender == _perpPool){
            require(unlocked, "lock");
        }
        
        if (_long0){
            if (!_isSizeCor)
                _sizeDelta = TradeMath.token1to0NoSpl(_sizeDelta, openPrice);
            _sizeDelta = IRoxPerpPool(_perpPool).reserve0().add(_sizeDelta) / 2;
        }
        else{
            if (!_isSizeCor)
                _sizeDelta = TradeMath.token0to1NoSpl(_sizeDelta, openPrice);
            _sizeDelta = IRoxPerpPool(_perpPool).reserve1().add(_sizeDelta) / 2;
        }
        uint256 _revtDelta = _long0 ?
                TradeMath.token0to1NoSpl(_sizeDelta, openPrice)
                :
                TradeMath.token1to0NoSpl(_sizeDelta, openPrice);

        uint256 spread256 = perpUtils.estimateImpact(_spotPool, _sizeDelta, _revtDelta, _long0);

        openPrice = _long0 ?
            uint160(FullMath.mulDiv(uint256(twapPrice), TradeMath.sqrt(spread256), 1000000))
            :
            uint160(FullMath.mulDiv(uint256(twapPrice), 1000000, TradeMath.sqrt(spread256)));

        openTick = TickMath.getTickAtSqrtRatio(openPrice);
        rtnSpread = uint24(spread256 / 1000000);
    }


    // get liq from: [tickFrom, tickTo]
    function getLiqArray(
        address spotPool,
        bool isToken0,
        uint256 amount
    ) public override view returns (uint256[] memory lqArray, uint128 latLiq, uint256 liqSum, int24 startRT) {
        if (isToken0) {
            // return perpUtils.calLiqArray0(spotPool, amount);
            try perpUtils.calLiqArray0(spotPool, amount) returns(uint256[] memory _lqArray, uint128 _latLiq, uint256 _liqSum, int24 _startPr)
            {
                return (_lqArray, _latLiq, _liqSum, _startPr);
            }catch (bytes memory ) {
                // revert("er0");//test only
                return (lqArray, 0, 0, 887600);
            }
        } 
        else {
            // return perpUtils.calLiqArray1(spotPool, amount);
            try perpUtils.calLiqArray1(spotPool, amount) returns(uint256[] memory _lqArray, uint128 _latLiq, uint256 _liqSum, int24 _startPr)
            {
                return (_lqArray, _latLiq, _liqSum, _startPr);
            }catch (bytes memory ) {
                // revert("er1"); //test only
                return (lqArray, 0,0, 887600);
            }
        } 
    }



 
    function getClosePrice(
        address _perpPool,
        bool _long0,
        uint256 _sizeDelta,
        bool _isCor
    ) public view override returns (uint256 closePrice) {
        TradeData.TradePosition memory tP;
        tP.long0 = _long0;
        tP.size = _sizeDelta;
        (closePrice, , ) = gClosePrice(_perpPool, _sizeDelta, tP, _isCor);
    }

    function gClosePrice(
        address _perpPool,
        uint256 _sizeDelta,
        TradeData.TradePosition memory tP,
        bool _isCor
    ) public view override returns (uint160 , uint160, uint24) {
        address _spotPool = IRoxPerpPool(_perpPool).spotPool();
        uint256 twapPrice = getSqrtTwapX96(_spotPool);
        // uint256 closePrice = twapPrice;
        // (uint160 curPrice, , , , , , ) = IRoxSpotPool(_spotPool).slot0();
        {
            ( , , , , , , bool unlocked ) = IRoxSpotPool(_spotPool).slot0();
            if (msg.sender == _perpPool){
                require(unlocked, "lock");
            }
        }

        if (!_isCor){
            if (tP.long0)
                _sizeDelta = TradeMath.token1to0NoSpl(_sizeDelta.add(tP.size), twapPrice);
            else
                _sizeDelta = TradeMath.token0to1NoSpl(_sizeDelta.add(tP.size), twapPrice);
        }else{
            if (tP.long0)
                _sizeDelta = _sizeDelta.add(TradeMath.token1to0NoSpl(tP.size, twapPrice));
            else
                _sizeDelta = _sizeDelta.add(TradeMath.token0to1NoSpl(tP.size, twapPrice));
        }
        
        uint256 spread_e12 = 1e12;
        {
            // countSize is sm as position dir.
            uint256 countSize = (_sizeDelta/4).add(countClose(_perpPool, tP.long0, getCountMin(_spotPool))); //globalLong0.div(2)

            uint256 _revtDelta = tP.long0 ?
                    TradeMath.token0to1NoSpl(countSize, twapPrice)
                    :
                    TradeMath.token1to0NoSpl(countSize, twapPrice);

            // spread_e12 = _estimateImpact(_spotPool, countSize, _revtDelta, tP.long0);
            // spread_e12 = perpUtilsestimateImpact(_spotPool, countSize, _revtDelta, tP.long0);
            try 
                perpUtils.estimateImpact(_spotPool, countSize, _revtDelta, tP.long0) returns (uint256 _estSpr)
            {
                spread_e12 = _estSpr;
            } catch (bytes memory) {
                spread_e12 = 1e12 + 2e10;
                // revert("err");//test only
            }
        }
        uint256 closePrice = twapPrice;
        if (tP.size > 0){
            uint256 sqSprede6 = TradeMath.sqrt(spread_e12);

            // long0 : 1 > 0, larger p
            twapPrice = tP.long0 ? 
                FullMath.mulDiv(twapPrice, 1000000 + FullMath.mulDiv(tP.collateral, sqSprede6 - 1000000, tP.size), 1000000)
                :
                FullMath.mulDiv(twapPrice, 1000000, 1000000 + FullMath.mulDiv(tP.collateral, sqSprede6 - 1000000, tP.size));
        }
        

        closePrice = tP.long0 ?
            uint160(FullMath.mulDiv(closePrice, 1000000, TradeMath.sqrt(spread_e12)))
            :
            uint160(FullMath.mulDiv(closePrice, TradeMath.sqrt(spread_e12), 1000000));


        return (uint160(closePrice), uint160(twapPrice), uint24(spread_e12 / 1000000));
    }



    function countClose(
        address _perpPool,
        bool long0,
        uint32 minC
    ) public view returns (uint256) {
        int256 amount = 0;
        uint32 cur_c = uint32(block.timestamp / 60);
        if (long0) {
            for (uint32 i = 0; i < minC + 1; i++) {
                amount +=  IRoxPerpPool(_perpPool).closeMinuteMap0(cur_c - i);
            }
        } else {
            for (uint32 i = 0; i < minC + 1; i++) {
                amount += IRoxPerpPool(_perpPool).closeMinuteMap1(cur_c - i);
            }
        }
        return amount > 0 ? uint256(amount) : 0;
    }



    function _factor(
        address _spotPool,
        uint256 _closePrice,
        TradeData.TradePosition memory tP,
        uint256 _delta) private view returns (uint128){

        if ((tP.long0 && _closePrice < tP.entrySqrtPriceX96)
            || (!tP.long0 && _closePrice > tP.entrySqrtPriceX96) ){       
            return 0;
        }
        CloseFactor memory _cf = cFt;

        uint256 dynamicTimeOp = 0;
        if (_cf.timeSecDynamic > 0){
            uint256 _tDur = uint256(_cf.timeSecDynamic);
            uint256 tGap = block.timestamp;
            require(tGap >= tP.openTime,"xOpTime");
            tGap = tGap.sub(tP.openTime);
            if (tGap < _tDur)
                dynamicTimeOp = FullMath.mulDiv(_delta, _tDur - tGap, _tDur);
        }

        uint256 tradeOp = 0; 
        uint256 s = uint256(_cf.factor_sf);
        if (s > 0){
            uint256 a = IRoxSpotPool(_spotPool).tInAccum0();
            a = a > tP.entryIn0 ? a.sub(tP.entryIn0) : 0;
            uint256 b = IRoxSpotPool(_spotPool).tInAccum1();
            b = b > tP.entryIn1 ? b.sub(tP.entryIn1) : 0;
            if (tP.long0){ //Long0, size Dis token: token1, change size tk1 to 0
                b = TradeMath.token1to0NoSpl(b, tP.entrySqrtPriceX96);
                if (b > a && tP.reserve < (b + a) ) { // && (tP.size < (a + b))) {
                    // s = FullMath.mulDiv(FullMath.mulDiv(s, b - a, a + b), _cf.factor_s, a + b);
                    // s = FullMath.mulDiv(FullMath.mulDiv(tP.reserve, b - a, a + b), _cf.factor_s, a + b) **_cf.powF;
                    s = FullMath.mulDiv(b - a, uint256(_cf.factor_s), a + b) ** uint256(_cf.powF);
                    tradeOp = FullMath.mulDiv(uint256(_cf.kMax).mul(s), _delta, uint256(_cf.factor_sf) * 1000);
                }
            }

            else{// Long1, sizeDis 0 -> 1
                a = TradeMath.token0to1NoSpl(a, tP.entrySqrtPriceX96);
                if (a > b && tP.reserve < (a + b)) {
                    s = FullMath.mulDiv(a - b, uint256(_cf.factor_s), a + b) ** uint256(_cf.powF);
                    tradeOp = FullMath.mulDiv(uint256(_cf.kMax).mul(s), _delta, uint256(_cf.factor_sf) * 1000);
                }
            }
        }

        tradeOp = tradeOp < dynamicTimeOp ? tradeOp : dynamicTimeOp;
        return uint128(tradeOp > _delta ? _delta  : tradeOp);//(closePrice, _sqrtSpd);
    }


    function getDelta(
        address _spotPool,
        uint256 _closePriceSqrtX96,
        TradeData.TradePosition memory tP) public override view returns (bool hasProfit, uint128 profitDelta, uint128 factorDelta) {
        if (tP.entrySqrtPriceX96 < 1)
            return(false, 0, 0);

        uint256 _openPriceX96 = FullMath.mulDiv(
            tP.entrySqrtPriceX96,
            tP.entrySqrtPriceX96,
            Q96
        );
        uint256 _closePriceX96 = FullMath.mulDiv(
            _closePriceSqrtX96,
            _closePriceSqrtX96,
            Q96
        );

        uint256 priceDelta = _openPriceX96 > _closePriceX96
            ? _openPriceX96 - _closePriceX96
            : _closePriceX96 - _openPriceX96;

        //Long0 :
        // delta = (P_0^close - P_0^open) / P_0^open
        //Long1 :
        // delta = (P_1^close - P_1^open) / P_1^open
        //       = ( 1/P_0^close) - 1/P_0^open) / (1 / P_0^open)
        //       = (P_0^open - P_0^close) / P_0^close
        if (tP.long0) {
            profitDelta = uint128(FullMath.mulDiv(tP.size, priceDelta, _openPriceX96));
            hasProfit = _closePriceX96 > _openPriceX96;
            // priceDelta = FullMath.mulDiv(1000000, priceDelta, _openPriceX96);
        } else {
            hasProfit = _openPriceX96 > _closePriceX96;
            profitDelta = uint128(FullMath.mulDiv(tP.size, priceDelta, _closePriceX96));
            // priceDelta = FullMath.mulDiv(1000000, priceDelta, _closePriceX96);
        }
        if (hasProfit){
            factorDelta = _factor(_spotPool, _closePriceSqrtX96, tP, profitDelta);
            profitDelta = profitDelta - factorDelta;
            uint128 resvForProfit = uint128(tP.long0 ? 
                    TradeMath.token0to1NoSpl(tP.reserve, _closePriceSqrtX96)
                    :
                    TradeMath.token1to0NoSpl(tP.reserve, _closePriceSqrtX96));
            if (profitDelta > resvForProfit)
                profitDelta = resvForProfit;
        }


    }


    function validPosition(
        uint256 collateral,
        uint256 size,
        address spotPool
    ) public override view returns (bool){
        require(collateral > 0, "pec");
        require(size > collateral, "pcs");
        require(collateral.mul(maxLeverage(spotPool)) > size, "maxL");
        return true;
    }

    function collectPosFee(
        uint256 size,
        address spotPool
    ) public override view returns (uint128){
        uint256 fee = IRoxSpotPool(spotPool).fee() * 2; // 3000 for 0.3%
        return uint128(FullMath.mulDiv(fee, size, 1000000));
    }


    function gFdPs(
        address _spotPool,
        address _posnPool,
        uint256 _reserve0,
        uint256 _reserve1
    ) public override view returns (uint32, uint32){
        uint256 l0rec = IRoxSpotPool(_spotPool).balance0();
        uint256 ucol0 = IRoxPosnPool(_posnPool).uncollect0();
        uint256 l1rec = IRoxSpotPool(_spotPool).balance1();
        uint256 ucol1 = IRoxPosnPool(_posnPool).uncollect1();
        uint256 fdps = fdFeePerS(_spotPool);
        return (
            uint32(l0rec > ucol0 ? FullMath.mulDiv(_reserve0, fdps, l0rec.sub(ucol0)) : 0),
            uint32(l1rec > ucol1 ? FullMath.mulDiv(_reserve1, fdps, l1rec.sub(ucol1)) : 0)
        );
    }


    function estimate(
        address spotPool,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 fee
    ) public view override returns (uint160 sqrtPrice, int256 amount0, int256 amount1, int24 endTick, uint128 endLiq)
    {
        return perpUtils.estimate(spotPool, zeroForOne, amountSpecified, fee);
    }

    function nextInitializedTickWithinOneWord(
        address spotPool,
        int24 tick,
        bool lte,
        int24 tickSpacing
    ) external view override returns (int24 next, bool initialized) {
        return perpUtils.nextInitializedTickWithinOneWord(spotPool, tick, lte, tickSpacing);
    }



    function availableReserve(
        address _spotPool,
        bool _l0, bool _l1
        ) public override view returns (uint256 r0, uint256 r1){
        // uint256 pr = TickRange.tickToPr(slot0.tick);
        int128 liquidity = int128(IRoxSpotPool(_spotPool).liquidity());
        if (liquidity < 1)
            return (0,0);
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = IRoxSpotPool(_spotPool).slot0();
        address roxPosnPool =  IRoxSpotPool(_spotPool).roxPosnPool();

        if (_l0){
            r0 = IRoxSpotPool(_spotPool).balance0();
            int24 rBound = TickRange.rightBoundaryTick(tick);
            uint160 rBoundSqrtPriceX96 = TickMath.getSqrtRatioAtTick(rBound);
            int256 curAmount = SqrtPriceMath.getAmount0Delta(
                    sqrtPriceX96,
                    rBoundSqrtPriceX96,
                    liquidity
                );

            (, int128 liquidityNet, , , ,  ) = IRoxSpotPool(_spotPool).ticks(rBound);
            // if (zeroForOne) liquidityNet = -liquidityNet;
            int24 rBound_t6 = tick + 600;
            if (rBound_t6 > rBound){
                    liquidity = liquidity + liquidityNet;
                    if (liquidity < 0)
                        curAmount = 0;//int256(r0);
                    else   
                        curAmount += SqrtPriceMath.getAmount0Delta(
                            rBoundSqrtPriceX96,
                            TickMath.getSqrtRatioAtTick(rBound_t6),
                            liquidity
                        );
            }
            uint256 c0 = uint256(curAmount >= 0 ? curAmount : -curAmount).add(IRoxPosnPool(roxPosnPool).uncollect0());
            r0 = r0 > c0 ? (r0 - c0) : 0;
        }
        if (_l1){
            r1 = IRoxSpotPool(_spotPool).balance1();
            int24 lBound = TickRange.leftBoundaryTickWithin(tick);
            uint160 lBoundSqrtPriceX96 = TickMath.getSqrtRatioAtTick(lBound);

            int256 curAmount = SqrtPriceMath.getAmount1Delta(
                    lBoundSqrtPriceX96,
                    sqrtPriceX96,
                    int128(liquidity));

            int24 lBound_t6 = tick - 600;
            if (lBound_t6 < lBound){
                (, int128 liquidityNet, , , ,  ) = IRoxSpotPool(_spotPool).ticks(lBound);
                liquidity = liquidity - liquidityNet;
                if (liquidity < 0)
                    curAmount = 0;//int256(r1);
                else
                    curAmount += SqrtPriceMath.getAmount1Delta(
                            TickMath.getSqrtRatioAtTick(lBound_t6),
                            lBoundSqrtPriceX96,
                            liquidity
                        );
            }
            uint256 c1 = uint256(curAmount >= 0 ? curAmount : -curAmount).add(IRoxPosnPool(roxPosnPool).uncollect1());
            r1 = r1 > c1 ? (r1 - c1) : 0;
        }
    }

}
