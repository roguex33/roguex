// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./interfaces/IRoxSpotPool.sol";
import "./interfaces/IRoxPerpPool.sol";
import "./interfaces/IRoxUtils.sol";
import "./interfaces/IRoguexFactory.sol";
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
import "hardhat/console.sol";

contract RoxUtils is IRoxUtils {
    using LowGasSafeMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;
    address public immutable factory;
    address public immutable override weth;

    uint32 public countMin = 10; // minutes;

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
    }
    
    struct CloseFactor{
        uint32 timeSec;
        uint16 kMax;
        uint8 powF;
        uint40 factor_s;
        uint160 factor_sf;
    }

    modifier onlyOwner() {
        require(msg.sender == IRoguexFactory(factory).owner(), "nOW");
        _;
    }

    constructor(address _factory, address _weth){
        factory = _factory;
        weth = _weth;
        cFt = CloseFactor({
            timeSec : 60 minutes,
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
            twapTime : 5 seconds
        } );
    }

    function setGlobalSetting(
        uint8 _maxLeverage,
        uint16 _spotThres,
        uint16 _perpThres,
        uint16 _setlThres,
        uint32 _fdFeePerS,
        uint32 _twapTime
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

        require(_fdFeePerS < 1e5);  // max 0.01% per sec.
        _gS.fdFeePerS = _fdFeePerS; //cal: size * fdFeePerS / 1e9  per sec
      
        require(_twapTime < 180); 
        _gS.twapTime = _twapTime; 
    
    }

    function modifyPoolSetting(
        address _spotPool, 
        uint8 _maxLeverage,
        uint16 _spotThres,
        uint16 _perpThres,
        uint16 _setlThres,
        uint32 _fdFeePerS,
        uint32 _twapTime,
        bool _del
        ) external {
        require(msg.sender == IRoguexFactory(factory).spotOwner(_spotPool), "OW");
        if (_del){
            delete poolSetting[_spotPool];
        }else{
            PoolSetting memory _gS = gSetting;
            require(_maxLeverage <= _gS.maxLeverage);
            require(_spotThres <= _gS.spotThres);
            require(_perpThres <= _gS.perpThres);
            require(_setlThres <= _gS.setlThres);
            require(_fdFeePerS <= _gS.fdFeePerS * 2);
            require(_twapTime < 180); 

            PoolSetting storage pSet = poolSetting[_spotPool];
            pSet.set = true;
            pSet.maxLeverage = _maxLeverage;
            pSet.spotThres = _spotThres;
            pSet.perpThres = _perpThres;
            pSet.setlThres = _setlThres;
            pSet.fdFeePerS = _fdFeePerS;
            pSet.twapTime = _twapTime; 
        }
    }



    function setTime(uint32 _countMin) external onlyOwner{
        require(_countMin < (60 minutes) / 60, "count min");
        countMin = _countMin;
    }

    function setFactor(
            uint256 _kMax, 
            uint256 _powF, 
            uint256 _timeSec
            ) external onlyOwner{
        require(_timeSec < 10 hours, "time max");
        require(_kMax < 1001, "k max"); // ratio > k / 1000
        require(_powF < 5, "max pow");  // ATTENTION:  overflow when pow > 4
        uint256 fs = 100 ** _powF;
        cFt = CloseFactor({
            kMax: uint16(_kMax),
            powF : uint8(_powF),
            factor_s : uint40(fs),
            factor_sf: uint160((fs)**_powF),
            timeSec : uint32(_timeSec)
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
 
        return getSqrtTwapX96Sec(spotPool, _pset.set ? _pset.twapTime : gSetting.twapTime);
    }

    function getSqrtTwapX96Sec(
        address spotPool,
        uint32 secAgo
    ) public view returns (uint160 sqrtPriceX96) {
        if (secAgo == 0) {
            (sqrtPriceX96, , , , , , ) = IRoxSpotPool(spotPool).slot0();
        } else {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = secAgo; // from (before)
            secondsAgos[1] = 0; // to (now)

            (int56[] memory tickCumulatives, ) = IRoxSpotPool(spotPool).observe(
                secondsAgos
            );
            // tick(imprecise as it's an integer) to price
            sqrtPriceX96 = TickMath.getSqrtRatioAtTick(
                int24((tickCumulatives[1] - tickCumulatives[0]) / secAgo)
            );
        }
    }

    function nextInitializedTickWithinOneWord(
        address spotPool,
        int24 tick,
        bool lte,
        int24 tickSpacing
    ) public view override returns (int24 next, bool initialized) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity

        if (lte) {
            (int16 wordPos, uint8 bitPos) = TradeMath.tkPosition(compressed);
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            uint256 masked = IRoxSpotPool(spotPool).tickBitmap(wordPos) & mask;

            initialized = masked != 0;
            next = initialized
                ? (compressed -
                    int24(bitPos - BitMath.mostSignificantBit(masked))) *
                    tickSpacing
                : (compressed - int24(bitPos)) * tickSpacing;
        } else {
            // start from the word of the next tick, since the current tick state doesn't matter
            (int16 wordPos, uint8 bitPos) = TradeMath.tkPosition(
                compressed + 1
            );
            // all the 1s at or to the left of the bitPos
            uint256 mask = ~((1 << bitPos) - 1);
            uint256 masked = IRoxSpotPool(spotPool).tickBitmap(wordPos) & mask;

            // if there are no initialized ticks to the left of the current tick, return leftmost in the word
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
            next = initialized
                ? (compressed +
                    1 +
                    int24(BitMath.leastSignificantBit(masked) - bitPos)) *
                    tickSpacing
                : (compressed + 1 + int24(type(uint8).max - bitPos)) *
                    tickSpacing;
        }
    }



    function estimate(
        address spotPool,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 fee
    )
        public
        view
        override
        returns (uint160 sqrtPrice, int256 amount0, int256 amount1, int24 endTick, uint128 endLiq)
    {
        require(amountSpecified != 0, "AS");
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = IRoxSpotPool(spotPool).slot0();

        // uint24 fee = IRoxSpotPool(spotPool).fee();

        bool exactInput = amountSpecified > 0;

        TradeData.SwapState memory state = TradeData.SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            liquidity: IRoxSpotPool(spotPool).liquidity(),
            feeGrowthGlobalX128: 0
        });
        while (state.amountSpecifiedRemaining != 0) {
            TradeData.StepComputations memory step;
            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            (
                step.tickNext,
                step.initialized
            ) = nextInitializedTickWithinOneWord(
                spotPool,
                state.tick,
                zeroForOne,
                600
            );
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);
            (
                state.sqrtPriceX96,
                step.amountIn,
                step.amountOut,
                step.feeAmount
            ) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            if (exactInput) {
                state.amountSpecifiedRemaining -= (step.amountIn +
                    step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated - (
                        step.amountOut.toInt256() );
            } else {
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated + (
                    (step.amountIn + step.feeAmount).toInt256()
                );
            }

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                if (step.initialized) {
                    (, int128 liquidityNet, , , ,  ) = IRoxSpotPool(spotPool)
                        .ticks(step.tickNext);
                    if (zeroForOne) liquidityNet = -liquidityNet;
                    state.liquidity = LiquidityMath.addDelta(
                        state.liquidity,
                        liquidityNet
                    );
                    require(state.liquidity > 0, "insuf. Liq");
                }
                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }


        (amount0, amount1) = zeroForOne == exactInput
            ? (
                amountSpecified - state.amountSpecifiedRemaining,
                state.amountCalculated
            )
            : (
                state.amountCalculated,
                amountSpecified - state.amountSpecifiedRemaining
            );

        return (state.sqrtPriceX96, amount0, amount1, state.tick, state.liquidity);
    }




    // get liq from: [tickFrom, tickTo]
    function getLiquidityArraySpecifiedStart(
        address spotPool,
        int24 curTick,
        int24 tickStart,
        bool isToken0,
        uint256 amount
    ) public override view returns (uint256[] memory, uint128 latLiq, uint256 liqSum) {
        if (isToken0)
            require(tickStart >= curTick, "s<c:xstart");
        else 
            require(tickStart <= curTick, "s>c:xstart");
        TradeData.PriceRangeLiq memory prState;
        {
            prState.tick = curTick;
            prState.tickStart = tickStart;
        }

        TradeData.LiqCalState memory state = TradeData.LiqCalState({
            amountSpecifiedRemaining: amount,
            sqrtPriceX96: TickMath.getSqrtRatioAtTick(tickStart),
            tick: prState.tick,
            liquidity: IRoxSpotPool(spotPool).liquidity()
        });

        if (isToken0) {
            return calLiqSpecifiedAmount0(spotPool, state, prState);
        } else if (tickStart < state.tick) {
            return calLiqSpecifiedAmount1(spotPool, state, prState);
        } else {
            revert("nsp");
        }
    }

   function calLiqSpecifiedAmount0(
        address spotPool,
        TradeData.LiqCalState memory state,
        TradeData.PriceRangeLiq memory prState) private view returns (uint256[] memory, uint128 endLiq, uint256 liqSum){
        require(prState.tickStart >= state.tick, "xDir0");
        uint256[] memory tkList = new uint256[](3000);

        while (state.amountSpecifiedRemaining != 0) {
            require(state.liquidity > 0, "outOfLiq0");
            require(prState.curIdx < 2999, "out of range");
            TradeData.StepComputations memory step;
            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            (
                step.tickNext,
                step.initialized
            ) = nextInitializedTickWithinOneWord(
                spotPool,
                state.tick,
                false,
                600
            );

            if (step.tickNext >= TickMath.MAX_TICK) 
                revert("outOfLiq0");

            if (step.tickNext - state.tick > 600) {
                step.tickNext = PriceRange.rightBoundaryTick(state.tick);
                step.initialized = false;
                //require(step.tickNext > state.tick)
            }
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            if (step.tickNext > prState.tickStart && step.tickNext != state.tick) {
                uint256 amounts = LiquidityAmounts.getAmount0ForLiquidity(
                    state.sqrtPriceX96,
                    step.sqrtPriceNextX96,
                    state.liquidity);
                tkList[prState.curIdx] = uint256(state.liquidity);
                if (amounts < state.amountSpecifiedRemaining){
                    state.amountSpecifiedRemaining -= amounts;
                    tkList[(prState.curIdx+=1)] = amounts;
                    prState.curIdx += 1;
                    liqSum +=  uint256(state.liquidity);
                }
                else{
                    endLiq = LiquidityAmounts.getLiquidityForAmount0(
                            state.sqrtPriceX96,
                            step.sqrtPriceNextX96,
                            state.amountSpecifiedRemaining);
                    tkList[(prState.curIdx+=1)] = state.amountSpecifiedRemaining;
                    prState.curIdx += 1;
                    state.amountSpecifiedRemaining = 0;
                    liqSum += uint256(endLiq);
                    break;
                }
            }

            if (step.initialized) {
                (, int128 liquidityNet, , , ,) = IRoxSpotPool(spotPool).ticks(step.tickNext);
                // if (zeroForOne) liquidityNet = - liquidityNet;
                state.liquidity = LiquidityMath.addDelta(
                    state.liquidity,
                    liquidityNet
                );
            }
            state.tick = step.tickNext;
            state.sqrtPriceX96 = step.sqrtPriceNextX96;
        }

        uint256[] memory tkL = new uint256[](prState.curIdx);
        for (uint256 i = 0; i < prState.curIdx; i++) {
            tkL[i] = tkList[i];
        }
        return (tkL, endLiq, liqSum);
    }


    function calLiqSpecifiedAmount1(
        address spotPool,
        TradeData.LiqCalState memory state,
        TradeData.PriceRangeLiq memory prState
    ) private view returns (uint256[] memory, uint128 endLiq,  uint256 liqSum) {
        uint256[] memory tkList = new uint256[](3000);
        require(prState.tickStart <= state.tick, "xDir1");
        while (state.amountSpecifiedRemaining != 0) {            
            require(state.liquidity > 0, "outOfLiq0");
            require(prState.curIdx < 2999, "out of range");
            TradeData.StepComputations memory step;
            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            (
                step.tickNext,
                step.initialized
            ) = nextInitializedTickWithinOneWord(
                spotPool,
                state.tick,
                true,
                600
            );

            if (step.tickNext <= TickMath.MIN_TICK) 
                revert("outOfLiq1");

            if (state.tick - step.tickNext > 600) {
                step.tickNext = PriceRange.leftBoundaryTick(state.tick);
                step.initialized = false;
            }
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);
            if (step.tickNext < prState.tickStart && step.tickNext != state.tick) {
                uint256 amounts =  LiquidityAmounts.getAmount1ForLiquidity(
                    step.sqrtPriceNextX96,
                    state.sqrtPriceX96,
                    state.liquidity);

                tkList[prState.curIdx] = uint256(state.liquidity);
                if (amounts < state.amountSpecifiedRemaining){
                    state.amountSpecifiedRemaining -= amounts;
                    tkList[(prState.curIdx+=1)] = amounts;
                    prState.curIdx += 1;
                    liqSum += uint256(state.liquidity);
                }
                else{
                    endLiq  =  LiquidityAmounts.getLiquidityForAmount1(
                            step.sqrtPriceNextX96,
                            state.sqrtPriceX96,
                            state.amountSpecifiedRemaining);
                    tkList[(prState.curIdx+=1)] = state.amountSpecifiedRemaining;
                    prState.curIdx += 1;
                    state.amountSpecifiedRemaining = 0;
                    liqSum += uint256(endLiq);
                    break;
                }
            }
            
            if (step.initialized) {
                (, int128 liquidityNet, , , ,) = IRoxSpotPool(spotPool).ticks(step.tickNext);
                // if (zeroForOne) liquidityNet = - liquidityNet;
                state.liquidity = LiquidityMath.addDelta(
                    state.liquidity,
                    -liquidityNet
                );
            }
            state.tick = step.tickNext - 1;
            state.sqrtPriceX96 = step.sqrtPriceNextX96;
        }
        // reverse from left to right
        uint256[] memory tkL = new uint256[](prState.curIdx);
        for (uint256 i = 0; i < prState.curIdx; i+=2) {
            tkL[i] = tkList[prState.curIdx - i - 2];
            tkL[i+1] = tkList[prState.curIdx - i - 1];
        }

        return (tkL, endLiq, liqSum);
    }


    function _estimateImpact(
        address _spotPool,
        uint256 _estiDelta,
        uint256 _revtDelta,
        bool _long0
    ) private view returns (uint256 spread){
        ( , int256 amount0, int256 amount1, ,) = estimate(
            _spotPool,
            !_long0,
            -int256(_estiDelta),
            0
        );


        if (_long0){
            // uint256 revtDelta = TradeMath.token0to1NoSpl(_estiDelta, curPrice);
            require(amount1 > 0, "r1neg");
            require(amount0 < 0 && _estiDelta == uint256(-amount0), "r0remained");
            spread = uint256(amount1) > _revtDelta ?
                FullMath.mulDiv(uint256(amount1), 1000000000000, _revtDelta)
                :
                1000001000000;
        }else{
            // uint256 revtDelta = TradeMath.token1to0NoSpl(_estiDelta, curPrice);
            require(amount0 > 0, "r0neg");
            require(amount1 < 0 && _estiDelta == uint256(-amount1), "r1remained");

            spread = uint256(amount0) > _revtDelta ?
                    FullMath.mulDiv(uint256(amount0), 1000000000000, _revtDelta)
                    :
                    1000001000000;
        }
        require(spread >= 1000000000000, "0spread");
    }

    function gOpenPrice(
        address _perpPool,
        uint256 _sizeDelta,
        bool _long0,
        bool _isSizeCor
    ) public view override returns (uint160 openPrice, int24 openTick, uint160 twapPrice, uint24 rtnSpread) {
        // OpenPricState memory ops;
        address _spotPool = IRoxPerpPool(_perpPool).spotPool();
        twapPrice = getSqrtTwapX96(_spotPool);
        (openPrice, , , , , , ) = IRoxSpotPool(_spotPool).slot0();
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

        uint256 spread256 = _estimateImpact(_spotPool, _sizeDelta, _revtDelta, _long0);

        openPrice = _long0 ?
            uint160(FullMath.mulDiv(uint256(twapPrice), TradeMath.sqrt(spread256), 1000000))
            :
            uint160(FullMath.mulDiv(uint256(twapPrice), 1000000, TradeMath.sqrt(spread256)));

        openTick = TickMath.getTickAtSqrtRatio(openPrice);
        rtnSpread = uint24(spread256 / 1000000);
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
    ) public view override returns (uint160 , uint160, uint24 ) {
        address _spotPool = IRoxPerpPool(_perpPool).spotPool();
        uint256 twapPrice = getSqrtTwapX96(_spotPool);
        // uint256 closePrice = twapPrice;
        // (uint160 curPrice, , , , , , ) = IRoxSpotPool(_spotPool).slot0();
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
            uint256 countSize = (_sizeDelta/4).add(countClose(_perpPool, tP.long0, countMin)); //globalLong0.div(2)

            uint256 _revtDelta = tP.long0 ?
                    TradeMath.token0to1NoSpl(countSize, twapPrice)
                    :
                    TradeMath.token1to0NoSpl(countSize, twapPrice);

            spread_e12 = _estimateImpact(_spotPool, countSize, _revtDelta, tP.long0);
        }
        uint256 closePrice = twapPrice;
        if (tP.size > 0){
            uint256 sqSprede6 = TradeMath.sqrt(spread_e12);

            // long0 : 1 > 0, larger p
            twapPrice = tP.long0 ? 
                FullMath.mulDiv(twapPrice, 1000000 + FullMath.mulDiv(tP.collateral, sqSprede6 - 1000000, tP.size), 1000000)
                :
                FullMath.mulDiv(twapPrice, 1000000, 1000000 + FullMath.mulDiv(tP.collateral, sqSprede6 - 1000000, tP.size));

            // twapPrice = tP.long0 ? 
            //     FullMath.mulDiv(twapPrice, sqSprede6, 1000000)
            //     :
            //     FullMath.mulDiv(twapPrice, 1000000, sqSprede6);
        }

        (closePrice, spread_e12) = _factor(_spotPool, closePrice, tP, spread_e12);

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
                amount +=  IRoxPerpPool(_perpPool).closeMinuteMap0(cur_c + i);
            }
        } else {
            for (uint32 i = 0; i < minC + 1; i++) {
                amount += IRoxPerpPool(_perpPool).closeMinuteMap1(cur_c + i);
            }
        }
        return amount > 0 ? uint256(amount) : 0;
    }



    function _factor(
        address _spotPool,
        uint256 _twapPrice,
        TradeData.TradePosition memory tP,
        uint256 _sqrtSpd) private view returns (uint256, uint256){

        uint256 closePrice = tP.long0 ?
            uint160(FullMath.mulDiv(_twapPrice, 1000000, TradeMath.sqrt(_sqrtSpd)))
            :
            uint160(FullMath.mulDiv(_twapPrice, TradeMath.sqrt(_sqrtSpd), 1000000));


        if ((tP.long0 && closePrice < tP.entrySqrtPriceX96)
            || (!tP.long0 && closePrice > tP.entrySqrtPriceX96) ){       
            return (closePrice, _sqrtSpd);
        }

        CloseFactor memory _cf = cFt;
        uint256 s = uint256(_cf.factor_sf);
        uint256 a = IRoxSpotPool(_spotPool).tInAccum0().sub(tP.entryIn0);
        uint256 b = IRoxSpotPool(_spotPool).tInAccum1().sub(tP.entryIn1);
        uint256 t = block.timestamp;
        require(t >= tP.openTime, "xTime");
        t = t.sub(tP.openTime);
        console.log("Gap T: ", t);
        if (tP.long0){ //Long0, size Dis token: token1, change size tk1 to 0
            b = TradeMath.token1to0NoSpl(b, tP.entrySqrtPriceX96);
            if (b > a && tP.reserve < (b + a) ) { // && (tP.size < (a + b))) {
                // s = FullMath.mulDiv(FullMath.mulDiv(s, b - a, a + b), _cf.factor_s, a + b);
                // s = FullMath.mulDiv(FullMath.mulDiv(tP.reserve, b - a, a + b), _cf.factor_s, a + b) **_cf.powF;
                s = FullMath.mulDiv(b - a, uint256(_cf.factor_s), a + b) **uint256(_cf.powF);
                uint256 pGap = uint256(closePrice).sub(tP.entrySqrtPriceX96);
                closePrice = closePrice.sub(FullMath.mulDiv(uint256(_cf.kMax).mul(s), pGap, uint256(_cf.factor_sf) * 1000));
                {
                    uint256 tDur = uint256(_cf.timeSec).mul(b-a)/(a+b);
                    if (t < tDur){
                        uint256 cP2 =  uint256(tP.entrySqrtPriceX96).add( FullMath.mulDiv(t ** 5, pGap, tDur ** 5) );
                        closePrice = cP2 < closePrice ? cP2 : closePrice;
                    }
                }

                
                _sqrtSpd = FullMath.mulDiv(_twapPrice, 1000000, closePrice)**2;
            }
        }

        else{// Long1, sizeDis 0 -> 1
            a = TradeMath.token0to1NoSpl(a, tP.entrySqrtPriceX96);
            if (a > b && tP.reserve < (a + b)) {
                s = FullMath.mulDiv(a - b, uint256(_cf.factor_s), a + b) ** uint256(_cf.powF);
                closePrice = closePrice.add(
                        FullMath.mulDiv(
                                uint256(_cf.kMax).mul(s), 
                                uint256(tP.entrySqrtPriceX96).sub(closePrice),
                                uint256(_cf.factor_sf) * 1000
                                )
                        );
              
                {
                    uint256 pGap = uint256(tP.entrySqrtPriceX96).sub(closePrice);
                    uint256 tDur = uint256(_cf.timeSec).mul(a-b)/(a+b);
                    if (t < tDur){
                        uint256 cP2 = FullMath.mulDiv(t ** 5, pGap, tDur ** 5) ;
                        cP2 = uint256(tP.entrySqrtPriceX96).sub( cP2);
                        closePrice = cP2 > closePrice ? cP2 : closePrice;
                    }
                }
                _sqrtSpd = FullMath.mulDiv(closePrice, 1000000, _twapPrice)**2;
            }
        }

        return (closePrice, _sqrtSpd);
    }


    function validPosition(
        uint256 collateral,
        uint256 size,
        address spotPool
    ) public override view returns (bool){
        require(collateral > 0, "empty collateral");
        require(size > collateral, "col > size");
        require(collateral.mul(maxLeverage(spotPool)) > size, "maxL");
        return true;
    }

    function collectPosFee(
        uint256 size,
        address spotPool
    ) public override view returns (uint256){
        uint256 fee = IRoxSpotPool(spotPool).fee() * 2; // 3000 for 0.3%
        return FullMath.mulDiv(fee, size, 1000000);
    }

}
