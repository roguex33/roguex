// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./interfaces/IRoxSpotPool.sol";
import "./interfaces/IRoxPerpPool.sol";
import "./interfaces/IRoxPosnPool.sol";
import "./interfaces/IPerpUtils.sol";
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
import "./libraries/TickRange.sol";


contract PerpUtils is IPerpUtils {
    uint256 internal constant Q96 = 0x1000000000000000000000000;
   
    using LowGasSafeMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;
    address public immutable factory;
    address public immutable weth;
    address public liqManager;

    CloseFactor public cFt;

    struct CloseFactor{
        uint16 timeSecDynamic;
        uint16 timeSecRange;
        uint16 kMax;
        uint8 powF;
        uint40 factor_s;
        uint160 factor_sf;
    }

    modifier onlyOwner() {
        require(msg.sender == IRoguexFactory(factory).owner(), "ow");
        _;
    }

    constructor(address _factory, address _weth){
        factory = _factory;
        weth = _weth;
        cFt = CloseFactor({
            timeSecDynamic : 60 minutes,
            timeSecRange : 60 minutes,
            kMax: 320,
            powF : 2,
            factor_s : 1e4,
            factor_sf: 1e8
        });
    }
    function setLiqManager(address _liqManager) external onlyOwner{
        liqManager = _liqManager;
    }

    function setFactor(
            uint256 _kMax, 
            uint256 _powF, 
            uint16 _timeSecDynamic,
            uint16 _timeSecRange
            ) external onlyOwner{
        require(_timeSecDynamic < 10 hours, "time max");
        require(_timeSecRange < 10 hours, "time range max");
        require(_kMax < 1001, "k max"); // ratio > k / 1000
        require(_powF < 5, "max pow");  // ATTENTION:  overflow when pow > 4
        uint256 fs = 100 ** _powF;
        cFt = CloseFactor({
            timeSecDynamic : uint16(_timeSecDynamic),
            timeSecRange : uint16(_timeSecRange),
            kMax: uint16(_kMax),
            powF : uint8(_powF),
            factor_s : uint40(fs),
            factor_sf: uint160((fs)**_powF)
        });
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


    struct StepComputations {
        uint160 sqrtPriceStartX96;
        int24 tickNext;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }


    function estimateImpact(
        address _spotPool,
        uint256 _estiDelta,
        uint256 _revtDelta,
        bool _long0
    ) external override view returns (uint256 spread){
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

    

    struct SwapState {
        int256 amountSpecifiedRemaining;
        int256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        uint256 feeGrowth;
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

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            liquidity: IRoxSpotPool(spotPool).liquidity(),
            feeGrowth: 0
        });
        while (state.amountSpecifiedRemaining != 0) {
            StepComputations memory step;
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



    struct LiqCalState {
        uint256 amountSpecifiedRemaining;
        
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 curIdx;

        uint128 liquidity;

    }

    

    function calLiqArray0(
        address spotPool,
        uint256 amountSpecifiedRemaining
    ) external override view returns (uint256[] memory, uint128 endLiq, uint256 liqSum, int24 startPr){
        LiqCalState memory state;
        // state init.
        {
            state.amountSpecifiedRemaining = amountSpecifiedRemaining;
            (, state.tick, , , , , ) = IRoxSpotPool(spotPool).slot0();
            state.tick = TickRange.rightBoundaryTick(state.tick);
            startPr = state.tick;
            state.sqrtPriceX96 = TickMath.getSqrtRatioAtTick(state.tick);

            (, int128 liquidityNet, , , ,) = IRoxSpotPool(spotPool).ticks(state.tick);
            state.liquidity = LiquidityMath.addDelta(
                IRoxSpotPool(spotPool).liquidity(),
                liquidityNet
            );
        }
        uint256[] memory tkList = new uint256[](1000);
        
        while (state.amountSpecifiedRemaining != 0) {
            require(state.liquidity > 0, "outOfLL0");
            require(state.curIdx < 998, "out of range");

            StepComputations memory step;
            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            step.tickNext = state.tick + 600;
            if (step.tickNext >= TickMath.MAX_TICK) 
                revert("outOfLiq0");

            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            uint256 amounts = LiquidityAmounts.getAmount0ForLiquidity(
                state.sqrtPriceX96,
                step.sqrtPriceNextX96,
                state.liquidity);

            tkList[state.curIdx] = uint256(state.liquidity);
            if (amounts < state.amountSpecifiedRemaining){
                state.amountSpecifiedRemaining -= amounts;
                tkList[(state.curIdx+=1)] = amounts;
                state.curIdx += 1;
                liqSum += uint256(state.liquidity);
            }
            else{
                endLiq = LiquidityAmounts.getLiquidityForAmount0(
                        state.sqrtPriceX96,
                        step.sqrtPriceNextX96,
                        state.amountSpecifiedRemaining);
                tkList[(state.curIdx+=1)] = state.amountSpecifiedRemaining;
                state.curIdx += 1;
                state.amountSpecifiedRemaining = 0;
                liqSum += uint256(endLiq);
                break;
            }
            
            {
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

        uint256[] memory tkL = new uint256[](state.curIdx);
        for (uint256 i = 0; i < state.curIdx; i++) {
            tkL[i] = tkList[i];
        }
        return (tkL, endLiq, liqSum, startPr);
    }



    function calLiqArray1(
        address spotPool,
        uint256 amountSpecifiedRemaining
    ) external override view returns (uint256[] memory, uint128 endLiq, uint256 liqSum, int24 startPr){
        LiqCalState memory state;
        // state init.
        {
            state.amountSpecifiedRemaining = amountSpecifiedRemaining;
            (, state.tick, , , , , ) = IRoxSpotPool(spotPool).slot0();
            state.tick = TickRange.leftBoundaryTickWithin(state.tick);            
            state.sqrtPriceX96 = TickMath.getSqrtRatioAtTick(state.tick);
            (, int128 liquidityNet, , , ,) = IRoxSpotPool(spotPool).ticks(state.tick);
            state.liquidity = LiquidityMath.addDelta(
                IRoxSpotPool(spotPool).liquidity(),
                -liquidityNet
            );
        }

        uint256[] memory tkList = new uint256[](1000);
        
        while (state.amountSpecifiedRemaining != 0) {
            require(state.liquidity > 0, "outOfLL1");
            require(state.curIdx < 998, "out of range");


            StepComputations memory step;
            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            step.tickNext = state.tick - 600;

            if (step.tickNext <= TickMath.MIN_TICK) 
                revert("outOfLiq1");

            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            uint256 amounts = LiquidityAmounts.getAmount1ForLiquidity(
                step.sqrtPriceNextX96,
                state.sqrtPriceX96,
                state.liquidity);

            tkList[state.curIdx] = uint256(state.liquidity);
            startPr = step.tickNext;
            if (amounts < state.amountSpecifiedRemaining){
                state.amountSpecifiedRemaining -= amounts;
                tkList[(state.curIdx+=1)] = amounts;
                state.curIdx += 1;
                liqSum += uint256(state.liquidity);
            }
            else{
                endLiq = LiquidityAmounts.getLiquidityForAmount1(
                        step.sqrtPriceNextX96,
                        state.sqrtPriceX96,
                        state.amountSpecifiedRemaining);
                tkList[(state.curIdx+=1)] = state.amountSpecifiedRemaining;
                state.curIdx += 1;
                state.amountSpecifiedRemaining = 0;
                liqSum += uint256(endLiq);
                break;
            }
            
            
            {
                (, int128 liquidityNet, , , ,) = IRoxSpotPool(spotPool).ticks(step.tickNext);
                state.liquidity = LiquidityMath.addDelta(
                    state.liquidity,
                    -liquidityNet
                );
            }

            state.tick = step.tickNext;
            state.sqrtPriceX96 = step.sqrtPriceNextX96;
        }

        // reverse from left to right
        uint256[] memory tkL = new uint256[](state.curIdx);
        for (uint256 i = 0; i < state.curIdx; i+=2) {
            tkL[i] = tkList[state.curIdx - i - 2];
            tkL[i+1] = tkList[state.curIdx - i - 1];
        }
        return (tkL, endLiq, liqSum, startPr);
    }



    function viewLiqArray0(
        address spotPool,
        uint24 prs
    ) external view returns (int256[] memory liqArray){
        LiqCalState memory state;
        liqArray = new int256[](prs);
        
        int256 curliq = int256(IRoxSpotPool(spotPool).liquidity() );
        liqArray[0] = curliq;
        // state init.
        {
            (, state.tick, , , , , ) = IRoxSpotPool(spotPool).slot0();
            state.tick = TickRange.rightBoundaryTick(state.tick);

            (, int128 liquidityNet, , , ,) = IRoxSpotPool(spotPool).ticks(state.tick);
            curliq = curliq + int256(liquidityNet);
        }

        for (uint256 i = 1; i < prs; i++) {

            StepComputations memory step;
            step.tickNext = state.tick + 600;

            liqArray[i] = int256(curliq);
            
            (, int128 liquidityNet, , , ,) = IRoxSpotPool(spotPool).ticks(step.tickNext);
            curliq = curliq + int256(liquidityNet);
            
            state.tick = step.tickNext;
        }

        return liqArray;
    }

    function viewLiqArray1(
        address spotPool,
        uint24 prs
    ) external view returns (int256[] memory liqArray){
        LiqCalState memory state;
        liqArray = new int256[](prs);

        int256 curliq = int256(IRoxSpotPool(spotPool).liquidity() );
        liqArray[0] = curliq;
        // state init.
        
        {
            (, state.tick, , , , , ) = IRoxSpotPool(spotPool).slot0();
            state.tick = TickRange.leftBoundaryTickWithin(state.tick);            

            (, int128 liquidityNet, , , ,) = IRoxSpotPool(spotPool).ticks(state.tick);
            curliq = curliq - int256(liquidityNet);
        }


        for (uint256 i = 1; i < prs; i++) {

            StepComputations memory step;
            step.tickNext = state.tick - 600;
            liqArray[i] = curliq;
            
            (, int128 liquidityNet, , , ,) = IRoxSpotPool(spotPool).ticks(step.tickNext);
            curliq = curliq - int256(liquidityNet);
            
            state.tick = step.tickNext;
        }

        return liqArray;
    }

}
