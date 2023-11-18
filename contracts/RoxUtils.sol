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


contract RoxUtils is IRoxUtils {
    using LowGasSafeMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;

    mapping(uint80 => string) public override errMsg;
    uint256 public constant RATIO_PREC = 1e6;
    uint256 public constant MAX_LEVERAGE = 80;


    uint32 public twapTime = 5; //15 minutes;
    uint32 public countMin = 10; //15 minutes;

    uint256 public override marginFeeBasisPoint = 0.0001e6;
    uint256 public override positionFeeBasisPoint = 0.002e6;
    uint256 public override fdFeePerS = 6e3;

    address public factory;
    address public override weth;
    CloseFactor public cFt;

    struct CloseFactor{
        uint256 kMax;
        uint256 powF;
        uint256 factor_s;
        uint256 factor_sf;
    }

    constructor(address _factory, address _weth){
        factory = _factory;
        weth = _weth;
        cFt = CloseFactor({
            kMax: 6,
            powF : 2,
            factor_s : 1e4,
            factor_sf: 1e8
        });
        // errMsg[0] = ""
    }


    function setTime(uint32 _time) external {
        require(msg.sender == IRoguexFactory(factory).owner(), "f-owner");
        twapTime = _time;
    }

    function setFactor(uint256 _kMax, uint256 _powF, uint32 _countMin) external {
        require(msg.sender == IRoguexFactory(factory).owner(), "f-owner");
        countMin = _countMin;
        uint256 fs = 100**_powF;
        cFt = CloseFactor({
            kMax: _kMax,
            powF : _powF,
            factor_s : fs,
            factor_sf: (fs)**_powF
        });
        // kMax = _kMax;
        // powF = _powF;
    }

    function getSqrtTwapX96(
        address spotPool
    ) public view override returns (uint160 sqrtPriceX96) {
        return getSqrtTwapX96Sec(spotPool, twapTime);
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
            // all the 1s at or to the right of the current bitPos
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            uint256 masked = IRoxSpotPool(spotPool).tickBitmap(wordPos) & mask;

            // if there are no initialized ticks to the right of or at the current tick, return rightmost in the word
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
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
        int256 amountSpecified
    )
        public
        view
        override
        returns (uint160 sqrtPrice, int256 amount0, int256 amount1, int24 endTick, uint128 endLiq)
    {
        require(amountSpecified != 0, "AS");
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = IRoxSpotPool(spotPool).slot0();

        uint24 fee = IRoxSpotPool(spotPool).fee();

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
    ) public override view returns (uint256[] memory, uint256 latLiq, uint256 liqSum) {
        // console.log("Check Amount : ", amount);
        // if (isToken0)
        //     require(tickStart >= curTick, "s<c:xstart");
        // else 
        //     require(tickStart <= curTick, "s>c:xstart");
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

        // TradeMath.printInt("curTick", state.tick);
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
        TradeData.PriceRangeLiq memory prState) private view returns (uint256[] memory, uint256 endLiq, uint256 liqSum){
        require(prState.tickStart >= state.tick, "xDir0");
        // TradeMath.printInt("tickStart : ", prState.tickStart);
        // TradeMath.printInt("tickState : ", state.tick);
        uint256[] memory tkList = new uint256[](3000);
        // bool zeroForOne = false; //Direction:  --->  In:Token1, Out:Token0

        while (state.amountSpecifiedRemaining != 0) {
            require(state.liquidity > 0, "outOfLiq0");
            require(prState.curIdx < 2999, "out of range");
            TradeData.StepComputations memory step;
            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            // step.tickNext = PriceRange.
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
                    liqSum += endLiq;
                    break;
                }
            }

            if (step.initialized) {
                (, int128 liquidityNet, , , ,) = IRoxSpotPool(spotPool).ticks(step.tickNext);
                // console.log(int256(liquidityNet));
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
    ) private view returns (uint256[] memory, uint256 endLiq,  uint256 liqSum) {
        uint256[] memory tkList = new uint256[](3000);
        // bool zeroForOne = true; //Direction:  <---  In:Token0, Out:Token1
        require(prState.tickStart <= state.tick, "xDir1");
        // TradeMath.printInt("tickStart : ", prState.tickStart);
        // TradeMath.printInt("tickState : ", state.tick);
        // TradeMath.printInt("tickStart: ", prState.tickStart);
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
            // console.log("prState.curIdx : ", prState.curIdx);
            // TradeMath.printInt("stickNext: ", step.tickNext);
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);
            if (step.tickNext < prState.tickStart && step.tickNext != state.tick) {
                uint256 amounts =  LiquidityAmounts.getAmount1ForLiquidity(
                    step.sqrtPriceNextX96,
                    state.sqrtPriceX96,
                    state.liquidity);

                tkList[prState.curIdx] = uint256(state.liquidity);
                if (amounts < state.amountSpecifiedRemaining){
                    state.amountSpecifiedRemaining -= amounts;
                    // console.log("liqF> : ", tkList[prState.curIdx]);
                    tkList[(prState.curIdx+=1)] = amounts;
                    prState.curIdx += 1;
                    liqSum += uint256(state.liquidity);
                }
                else{
                    endLiq  =  LiquidityAmounts.getLiquidityForAmount1(
                            step.sqrtPriceNextX96,
                            state.sqrtPriceX96,
                            state.amountSpecifiedRemaining);
                    // console.log("liqP> : ", tkList[prState.curIdx]);
                    tkList[(prState.curIdx+=1)] = state.amountSpecifiedRemaining;
                    prState.curIdx += 1;
                    state.amountSpecifiedRemaining = 0;
                    liqSum += endLiq;
                    break;
                }
            }
            
            if (step.initialized) {
                (, int128 liquidityNet, , , ,) = IRoxSpotPool(spotPool).ticks(step.tickNext);
                // console.log(int256(liquidityNet));
                // if (zeroForOne) liquidityNet = - liquidityNet;
                state.liquidity = LiquidityMath.addDelta(
                    state.liquidity,
                    -liquidityNet
                );
            }
            state.tick = step.tickNext - 1;
            state.sqrtPriceX96 = step.sqrtPriceNextX96;
        }
        // console.log("lt0 bef: ", tkList[0] );
        // console.log("lt1 bef: ", tkList[1] );
        // reverse from left to right
        uint256[] memory tkL = new uint256[](prState.curIdx);
        for (uint256 i = 0; i < prState.curIdx; i+=2) {
            tkL[i] = tkList[prState.curIdx - i - 2];
            tkL[i+1] = tkList[prState.curIdx - i - 1];
        }
        // console.log("tk0 aft: ", tkL[0] );
        
        return (tkL, endLiq, liqSum);
    }

    function token0t1NoSpl(
        address _spotPool,
        uint256 _amount0
    ) public view returns (uint256) {
        // protect from flash attach
        return TradeMath.token0to1NoSpl(_amount0, uint256(getSqrtTwapX96Sec(_spotPool, 1)));
    }

    function token1t0NoSpl(
        address _spotPool,
        uint256 _amount1
    ) public view returns (uint256) {
        // protect from flash attach
        return TradeMath.token1to0NoSpl(_amount1, uint256(getSqrtTwapX96Sec(_spotPool, 1)));
    }




    function gOpenPrice(
        address _roguPool,
        uint256 _sizeDelta,
        bool _long0,
        bool _isSizeCor
    ) public view override returns (uint160, int24, uint160, int24) {
        TradeData.OpenPricState memory ops;

        {
            address _spotPool = IRoxPerpPool(_roguPool).spotPool();
            ops.openPrice = getSqrtTwapX96(_spotPool);
            (ops.curPrice, ops.curTick, , , , , ) = IRoxSpotPool(_spotPool).slot0();
            if (!_isSizeCor){
                if (_long0)
                    _sizeDelta = TradeMath.token1to0NoSpl(_sizeDelta, ops.curPrice);
                else
                    _sizeDelta = TradeMath.token0to1NoSpl(_sizeDelta, ops.curPrice);
            }
            int256 estiDelta = int256(_long0 ? 
                        IRoxPerpPool(_roguPool).reserve0().add(_sizeDelta) / 2
                        :
                        IRoxPerpPool(_roguPool).reserve1().add(_sizeDelta) / 2);
            (ops.sqrtPriceX96, , , ,) = estimate(
                _spotPool,
                !_long0,
                -estiDelta
            );
        }



        if (_long0) {
            // uint256 _amounCt = globalLong0.add(_sizeDelta).div(2);
            // (ops.sqrtPriceX96, , , ,) = estimate(
            //     _spotPool,
            //     !_long0,
            //     - int256(
            //         IRoxPerpPool(_roguPool).reserve0().add(_sizeDelta).div(2)
            //     )
            // );
            require(ops.sqrtPriceX96 >= ops.curPrice, "Open>P");
            ops.openPrice = ops.openPrice > ops.curPrice
                ? ops.openPrice
                : ops.curPrice;
            // openPrice += FullMath.mulDiv(openPrice, uint256(sqrtPriceX96 - curPrice), curPrice);
            ops.openPrice += ops.sqrtPriceX96 - ops.curPrice;
        } else {
            // (ops.sqrtPriceX96, , , ,) = estimate(
            //     _spotPool,
            //     !_long0,
            //     - int256(
            //         IRoxPerpPool(_roguPool).reserve1().add(_sizeDelta).div(2)
            //     )
            // );
            require(ops.sqrtPriceX96 <= ops.curPrice, "Open<P");
            ops.openPrice = ops.openPrice < ops.curPrice
                ? ops.curPrice
                : ops.openPrice;

            ops.openPrice = ops.openPrice - (ops.curPrice - ops.sqrtPriceX96);
            // ops.openPrice =
            //     ops.openPrice -
            //     uint160(
            //         FullMath.mulDiv(
            //             ops.openPrice,
            //             uint256(ops.curPrice - ops.sqrtPriceX96),
            //             ops.curPrice
            //         )
            //     ); //same
        }
        ops.openTick = TickMath.getTickAtSqrtRatio(ops.openPrice);

        return (ops.openPrice, ops.openTick, ops.curPrice, ops.curTick);

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
        (closePrice, ) = gClosePrice(_perpPool, _sizeDelta, tP, _isCor);
    }

    function gClosePrice(
        address _roguPool,
        uint256 _sizeDelta,
        TradeData.TradePosition memory tP,
        bool _isCor
    ) public view override returns (uint160 , uint160 ) {
        address _spotPool = IRoxPerpPool(_roguPool).spotPool();
        uint256 twapPrice = getSqrtTwapX96(_spotPool);
        uint256 closePrice = twapPrice;
        (uint160 curPrice, , , , , , ) = IRoxSpotPool(_spotPool).slot0();

        if (!_isCor){
            if (tP.long0)
                _sizeDelta = TradeMath.token1to0NoSpl(_sizeDelta, curPrice);
            else
                _sizeDelta = TradeMath.token0to1NoSpl(_sizeDelta, curPrice);
        }

        // uint256 closePrice 
        // countSize is sm as position dir.
        uint256 countSize = (_sizeDelta/2).add(countClose(_roguPool, tP.long0, countMin)); //globalLong0.div(2)
        (uint160 sqrtPriceX96est, , , ,) = estimate(
            _spotPool,
            !tP.long0,
            -int256(countSize)
        ); //
        if (tP.long0) {
            require(sqrtPriceX96est > curPrice, "Close<P");
            closePrice = twapPrice < curPrice ? twapPrice : curPrice;
            closePrice = closePrice.sub(
                _factor(_spotPool, tP, _sizeDelta, uint256(sqrtPriceX96est - curPrice))
            );
        } else {
            require(sqrtPriceX96est < curPrice, "Close>P");
            closePrice = twapPrice > curPrice ? twapPrice : curPrice;   
            closePrice = closePrice.add(
                _factor(_spotPool, tP, _sizeDelta, uint256(curPrice - sqrtPriceX96est))
            );
        }
        
        return (uint160(closePrice), uint160(twapPrice));
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
        address _spotPool, TradeData.TradePosition memory tP, uint256 _sizeDelta, uint256 _sqrtSpd) private view returns (uint256){
        CloseFactor memory _cf = cFt;
        uint256 s = _cf.factor_sf;
        uint256 a = IRoxSpotPool(_spotPool).liqAccum0().sub(tP.entryLiq0);
        uint256 b = IRoxSpotPool(_spotPool).liqAccum1().sub(tP.entryLiq1);
        if (tP.long0){
            if (a > b && (tP.sizeLiquidity < (a + b))) {
                s = FullMath.mulDiv(
                    tP.sizeLiquidity,
                    _sizeDelta,
                    tP.size
                );
                s = FullMath.mulDiv(FullMath.mulDiv(s, a - b, a + b), _cf.factor_s, a + b);
                // unchecked {
                uint256 _k = (_cf.kMax * 3000) /
                    IRoxSpotPool(_spotPool).fee();
                console.log(">>> k ", _k);
                // console.log(">>> fee ", IRoxSpotPool(_spotPool).fee());
                s = (s ** _cf.powF) * _k + _cf.factor_sf;
                // }
            }else{
                return _sqrtSpd;
            }
        }

        else{
            if (a < b && (uint256(tP.sizeLiquidity) < (a + b))) {
                s = FullMath.mulDiv(
                    tP.sizeLiquidity,
                    _sizeDelta,
                    tP.size
                );
                s = FullMath.mulDiv(FullMath.mulDiv(s, b - a, a + b), _cf.factor_s, a + b);
                uint256 _k = (_cf.kMax * 3000) /
                    IRoxSpotPool(_spotPool).fee();
                console.log(">>> k ", _k);
                // console.log(">>> fee ", IRoxSpotPool(_spotPool).fee());
                s = (s ** _cf.powF) * _k + _cf.factor_sf;
            }else{
                return _sqrtSpd;
            }
        }
        return FullMath.mulDiv(_sqrtSpd, s, _cf.factor_sf);
    }


    function validPosition(
        uint256 collateral,
        uint256 size
    ) public override pure returns (bool){
        require(collateral > 0, "empty collateral");
        require(size > collateral, "col > size");
        require(collateral.mul(MAX_LEVERAGE) > size, "maxL");
        return true;
    }

    function collectPosFee(
        uint256 size
    ) public override view returns (uint256){
        return FullMath.mulDiv(positionFeeBasisPoint, size, RATIO_PREC);
    }

}
