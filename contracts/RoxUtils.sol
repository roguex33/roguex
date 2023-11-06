// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "./interfaces/IRoxSpotPoolDeployer.sol";
import "./interfaces/IRoxPerpPoolDeployer.sol";
import "./interfaces/IRoxSpotPool.sol";
import "./interfaces/IRoxPerpPool.sol";
import "./interfaces/IERC20Minimal.sol";
import './libraries/SqrtPriceMath.sol';
import "./libraries/RoxPosition.sol";

import "./interfaces/IRoxUtils.sol";
import "./interfaces/IRoguexFactory.sol";

import "./libraries/TransferHelper.sol";
import "./libraries/EnumerableValues.sol";
import "./libraries/TradeData.sol";
import "./libraries/TradeMath.sol";

import "./libraries/LowGasSafeMath.sol";
import "./libraries/SafeCast.sol";
import "./libraries/Tick.sol";
import "./libraries/TickBitmap.sol";
import "./libraries/Position.sol";
import "./libraries/Oracle.sol";

import "./libraries/FullMath.sol";
import "./libraries/FixedPoint128.sol";
import "./libraries/TickMath.sol";
import "./libraries/LiquidityMath.sol";
import "./libraries/SqrtPriceMath.sol";
import "./libraries/SwapMath.sol";

import "hardhat/console.sol";

interface IFactory {
    function approvedRouters(address _router) external view returns (bool);
}

interface ITk {
    function decimals() external view returns (uint8);
}

contract RoxUtils is IRoxUtils {
    using SafeMath for uint256;
    using SafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;


    uint256 public constant RATIO_PREC = 1e6;


    uint32 public twapTime = 5; //15 minutes;
    uint32 public countMin = 10; //15 minutes;

    uint256 public override marginFeeBasisPoint = 0.0001e6;
    uint256 public override positionFeeBasisPoint = 0.002e6;
    uint256 public override fdFeePerS = 12;

    uint256 public kMax = 6;
    uint256 public powF = 2;
    bool public _t;

    address public factory;
    address public weth;

    struct CloseFactor{
        uint16 countMin;
        uint32 kMax;
        uint32 powF;
        uint80 factor_s;
        uint80 factor_sf;
    }

    constructor(address _factory, address _weth){
        factory = _factory;
        weth = _weth;
    }
    //TEST ONLY :::
    function setTime(uint32 _time) external {
        require(msg.sender == IRoguexFactory(factory).owner(), "f-owner");
        twapTime = _time;
    }

    function setFactor(uint256 _kMax, uint256 _powF, uint32 _countMin) external {
        require(msg.sender == IRoguexFactory(factory).owner(), "f-owner");
        countMin = _countMin;
        kMax = _kMax;
        powF = _powF;
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

    // zeroForOne: -true for token0 to token1, false for token1 to token0
    // get liq from: [tickFrom, tickTo]
    function getLiq(
        address spotPool,
        int24 tickFrom,
        int24 tickTo
    ) public view returns (uint128) {
        (, int24 curTick, , , , , ) = IRoxSpotPool(spotPool).slot0();
        int24 tickSpacing = 600; // IRoxSpotPool(spotPool).tickSpacing();

        uint128 liqTick = IRoxSpotPool(spotPool).liquidity();
        uint128 liqAccumFrom;
        uint128 liqAccumTo;
        if (tickFrom > curTick) {
            tickFrom = tickFrom - 1;
            require(tickFrom < tickTo, "t=");
            bool zeroForOne = false;
            while (curTick <= tickTo) {
                (
                    int24 tickNext,
                    bool nextInitialized
                ) = nextInitializedTickWithinOneWord(
                        spotPool,
                        curTick,
                        zeroForOne,
                        tickSpacing
                    );
                if (tickNext < TickMath.MIN_TICK) {
                    tickNext = TickMath.MIN_TICK;
                } else if (tickNext > TickMath.MAX_TICK) {
                    tickNext = TickMath.MAX_TICK;
                }
                require(tickNext >= curTick, "nVDir+");

                if (curTick <= tickFrom) {
                    liqAccumFrom =
                        liqAccumFrom +
                        uint128(
                            (tickNext >= tickFrom ? tickFrom : tickNext) -
                                curTick +
                                1
                        ) *
                        liqTick;
                }
                if (curTick <= tickTo) {
                    liqAccumTo =
                        liqAccumTo +
                        uint128(
                            (tickNext >= tickTo ? tickTo : tickNext) -
                                curTick +
                                1
                        ) *
                        liqTick;
                }
                if (curTick == tickNext) {
                    if (nextInitialized) {
                        (, int128 liquidityNet, , , , ) = IRoxSpotPool(
                            spotPool
                        ).ticks(tickNext);
                        liqTick = LiquidityMath.addDelta(liqTick, liquidityNet);
                        liqAccumFrom = LiquidityMath.addDelta(
                            liqAccumFrom,
                            liquidityNet
                        );
                        liqAccumTo = LiquidityMath.addDelta(
                            liqAccumTo,
                            liquidityNet
                        );
                    }
                    curTick = tickNext;
                } else {
                    curTick = tickNext;
                }
            }
        } else if (tickFrom < curTick) {
            tickFrom = tickFrom + 1;
            require(tickFrom > tickTo, "t-=");
            bool zeroForOne = true;
            while (curTick <= tickTo) {
                (
                    int24 tickNext,
                    bool nextInitialized
                ) = nextInitializedTickWithinOneWord(
                        spotPool,
                        curTick,
                        zeroForOne,
                        tickSpacing
                    );
                if (tickNext < TickMath.MIN_TICK) {
                    tickNext = TickMath.MIN_TICK;
                } else if (tickNext > TickMath.MAX_TICK) {
                    tickNext = TickMath.MAX_TICK;
                }
                require(curTick >= tickNext, "nVDir-");
                if (curTick >= tickFrom) {
                    liqAccumFrom =
                        liqAccumFrom +
                        uint128(
                            curTick -
                                (tickNext >= tickFrom ? tickNext : tickFrom) +
                                1
                        ) *
                        liqTick;
                }
                if (curTick >= tickTo) {
                    liqAccumTo =
                        liqAccumTo +
                        uint128(
                            curTick -
                                (tickNext >= tickTo ? tickNext : tickTo) +
                                1
                        ) *
                        liqTick;
                }

                if (curTick == tickNext) {
                    if (nextInitialized) {
                        (, int128 liquidityNet, , , , ) = IRoxSpotPool(
                            spotPool
                        ).ticks(tickNext);
                        // if (zeroForOne) liquidityNet = - liquidityNet;
                        liqTick = LiquidityMath.addDelta(
                            liqTick,
                            -liquidityNet
                        );
                        liqAccumFrom = LiquidityMath.addDelta(
                            liqAccumFrom,
                            liquidityNet
                        );
                        liqAccumTo = LiquidityMath.addDelta(
                            liqAccumTo,
                            liquidityNet
                        );
                    }
                    // curTick = zeroForOne ? tickNext - 1 : tickNext;
                    curTick = tickNext - 1;
                } else {
                    curTick = tickNext;
                }
            }
        } else {
            revert("not suppoted.");
        }
        return liqAccumFrom < liqAccumTo ? liqAccumTo - liqAccumFrom : 0;
    }

    // zeroForOne:> true for token0 to token1, false for token1 to token0
    // get liq from: [tickFrom, tickTo]
    function getLiqDetails(
        address spotPool,
        int24 tickStart,
        uint256 amount
    ) public view override returns (int256[] memory, int24) {
        TradeData.PriceRangeLiq memory prState;
        (, prState.tick, , , , , ) = IRoxSpotPool(spotPool).slot0();
        require(tickStart != prState.tick, "nEq");
        //PriceRangeLiq init.
        {
            prState.tickStart = tickStart;
            prState.tickSpacing = 600; //IRoxSpotPool(spotPool).tickSpacing();
            // prState.fee = IRoxSpotPool(spotPool).fee();
            prState.prStart = uint16(TradeMath.tickToPr(tickStart));
        }

        // require(tickFrom % 600 == 0, "nPR"); // ensure that the tick is spaced
        TradeData.SwapState memory state = TradeData.SwapState({
            amountSpecifiedRemaining: amount.toInt256(),
            amountCalculated: 0,
            sqrtPriceX96: TickMath.getSqrtRatioAtTick(tickStart),
            tick: prState.tick,
            liquidity: IRoxSpotPool(spotPool).liquidity(),
            feeGrowthGlobalX128: 0
        });

        // TradeMath.printInt(">>>> tickStart  :", tickStart);
        // TradeMath.printInt(">>>> state.tick :", state.tick);

        if (tickStart > state.tick) {
            return calLiq1(spotPool, state, prState);
        } else if (tickStart < state.tick) {
            return calLiq0(spotPool, state, prState);
        } else {
            revert("not support");
        }
    }

    function calLiq1(
        address spotPool,
        TradeData.SwapState memory state,
        TradeData.PriceRangeLiq memory prState) private view returns (int256[] memory, int24 tickEnd){

        int256[] memory tkList = new int256[](3000);
        bool zeroForOne = false; //Direction:  --->  In:Token1, Out:Token0

        tkList[0] = int256(state.liquidity);
        tkList[1] = state.tick;

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
                prState.tickSpacing
            );
            // TradeMath.printInt(">>>> step.tickNext  :", step.tickNext);

            if (zeroForOne) {// 0 to 1, price <---- 
                if (state.tick - step.tickNext > 600) {
                    step.tickNext = TradeMath.leftBoundaryTick(state.tick);
                    step.initialized = false;
                }

            } else {//1 to 0, price ---->
                if (step.tickNext - state.tick > 600) {
                    step.tickNext = TradeMath.rightBoundaryTick(state.tick);
                    step.initialized = false;
                }
            }

            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // console.log(">>>> curPr : ", curPr);
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);
            if (step.tickNext > prState.tickStart) {
                (state.sqrtPriceX96, step.amountIn, , step.feeAmount) = SwapMath
                    .computeSwapStep(
                        state.sqrtPriceX96,
                        step.sqrtPriceNextX96,
                        state.liquidity,
                        state.amountSpecifiedRemaining,
                        prState.fee
                    );
                //initialized range must eq.
                state.amountSpecifiedRemaining -= (step.amountIn +
                    step.feeAmount).toInt256();

                if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                    if (step.initialized) {
                        (, int128 liquidityNet, , , ,) = IRoxSpotPool(
                            spotPool
                        ).ticks(step.tickNext);
                        // console.log(int256(liquidityNet));
                        // if (zeroForOne) liquidityNet = - liquidityNet;
                        state.liquidity = LiquidityMath.addDelta(
                            state.liquidity,
                            liquidityNet
                        );
                        require(state.liquidity > 0, "outOfLiq.");
                        if (step.tickNext > prState.tickStart) {
                            prState.curIdx += 2;
                            tkList[prState.curIdx] = int256(state.liquidity);
                            tkList[prState.curIdx + 1] = state.tick;
                        }
                    }
                    // state.tick = step.tickNext;
                } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                    // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                    // state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
                }
                state.tick = step.tickNext;
            } else {
                if (step.initialized) {
                    (, int128 liquidityNet, , , , ) = IRoxSpotPool(spotPool)
                        .ticks(step.tickNext);
                    state.liquidity = LiquidityMath.addDelta(
                        state.liquidity,
                        liquidityNet
                    );
                    require(state.liquidity > 0, "outOfLiq.");
                }
                tkList[0] = int256(state.liquidity);
                tkList[1] = state.tick;
                state.tick = step.tickNext;
            }
        }
        tickEnd = state.tick;
        uint256 length = prState.curIdx + 2;
        int256[] memory tkL = new int256[](length);
        for (uint256 i = 0; i < length; i++) {
            tkL[i] = tkList[i];
        }
        return (tkL, tickEnd);
    }

    function calLiq0(
        address spotPool,
        TradeData.SwapState memory state,
        TradeData.PriceRangeLiq memory prState
    ) private view returns (int256[] memory, int24 tickEnd) {
        int256[] memory tkList = new int256[](3000);
        bool zeroForOne = true; //Direction:  <---  In:Token0, Out:Token1

        tkList[0] = int256(state.liquidity);
        tkList[1] = state.tick;

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
                prState.tickSpacing
            );

            if (zeroForOne) {// 0 to 1, price <---- 
                if (state.tick - step.tickNext > 600) {
                    step.tickNext = TradeMath.leftBoundaryTick(state.tick);
                    step.initialized = false;
                }
            } else {//1 to 0, price ---->
                if (step.tickNext - state.tick > 600) {
                    step.tickNext = TradeMath.rightBoundaryTick(state.tick);
                    step.initialized = false;
                }
            }

            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);
            if (step.tickNext < prState.tickStart) {
                (state.sqrtPriceX96, step.amountIn, , step.feeAmount) = SwapMath
                    .computeSwapStep(
                        state.sqrtPriceX96,
                        step.sqrtPriceNextX96,
                        state.liquidity,
                        state.amountSpecifiedRemaining,
                        prState.fee
                    );
                //initialized range must eq.
                state.amountSpecifiedRemaining -= (step.amountIn +
                    step.feeAmount).toInt256();

                if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                    if (step.initialized) {
                        (, int128 liquidityNet, , , ,) = IRoxSpotPool(
                            spotPool
                        ).ticks(step.tickNext);
                        state.liquidity = LiquidityMath.addDelta(
                            state.liquidity,
                            -liquidityNet
                        );
                        if (step.tickNext < prState.tickStart) {
                            prState.curIdx += 2;
                            tkList[prState.curIdx] = int256(state.liquidity);
                            tkList[prState.curIdx + 1] = state.tick;
                        }
                    }
                    state.tick = step.tickNext - 1;
                } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                    // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                    state.tick = TickMath.getTickAtSqrtRatio(
                        state.sqrtPriceX96
                    );
                }
            } else {
                if (step.initialized) {
                    (, int128 liquidityNet, , , ,) = IRoxSpotPool(spotPool)
                        .ticks(step.tickNext);
                    state.liquidity = LiquidityMath.addDelta(
                        state.liquidity,
                        -liquidityNet
                    );
                }
                tkList[0] = int256(state.liquidity);
                tkList[1] = state.tick;
                state.tick = step.tickNext - 1;
            }
        }

        tickEnd = state.tick;
        uint256 length = prState.curIdx + 2;
        int256[] memory tkL = new int256[](length);
        for (uint256 i = 0; i < length; i++) {
            tkL[i] = tkList[i];
        }
        return (tkL, tickEnd);
    }

    function estimate(
        address spotPool,
        bool zeroForOne,
        bool usingLiq,
        int256 amountSpecified
    )
        public
        view
        override
        returns (uint160 sqrtPrice, uint256 amount, int24 endTick)
    {
        require(amountSpecified > 0, "asl0");
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = IRoxSpotPool(spotPool)
            .slot0();
        if (amountSpecified < 1) return (sqrtPriceX96, 0, 0);
        int256 amountToken = amountSpecified;
        if (usingLiq) {
            if (zeroForOne) {
                amountToken = amountSpecified / int256(sqrtPriceX96);
            } else {
                amountToken = amountSpecified * int256(sqrtPriceX96);
            }
        }
        int24 tickSpacing = 600;
        uint24 fee = IRoxSpotPool(spotPool).fee();
        // amountToken = zeroForOne
        // ? amountToken + int256(reserve0)
        // : amountToken + int256(reserve1);

        TradeData.SwapState memory state = TradeData.SwapState({
            amountSpecifiedRemaining: amountToken,
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
                tickSpacing
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
            state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount)
                .toInt256();

            // if (state.liquidity > 0)
            //     state.feeGrowthGlobalX128 += FullMath.mulDiv(
            //         step.feeAmount,
            //         FixedPoint128.Q128,
            //         state.liquidity
            //     );
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

        return (state.sqrtPriceX96, uint256(amountToken), state.tick);
    }

    function getFlLiqsWithinTick(
        address spotPool,
        int24 startTick,
        int24 endTick
    ) public view returns (uint256[] memory liqL) {
        return
            getFlLiqs(
                spotPool,
                TradeMath.tickToPr(startTick),
                TradeMath.tickToPr(endTick)
            );
    }

    function getFlLiqs(
        address spotPool,
        uint256 startPr,
        uint256 endPr
    ) public view returns (uint256[] memory liqL) {
        require(endPr >= startPr, "xOr");
        TradeData.PriceRangeLiq memory prState;
        (, prState.tick, , , , , ) = IRoxSpotPool(spotPool).slot0();
        prState.prStart = uint16(TradeMath.tickToPr(prState.tick));

        liqL = new uint256[](endPr - startPr + 1);
        uint128 liq = IRoxSpotPool(spotPool).liquidity();
        // TradeMath.printInt("prState.tick: ", prState.tick);
        // tkList[0] = int256(state.liquidity);
        // tkList[1] = state.tick;
        // console.log(">>> startPr: ", startPr, "      endPr: ", endPr);
        if (startPr >= prState.prStart) {
            uint cPr = prState.prStart;
            TradeData.StepComputations memory step;
            while (cPr <= endPr) {
                (
                    step.tickNext,
                    step.initialized
                ) = nextInitializedTickWithinOneWord(
                    spotPool,
                    prState.tick,
                    false,
                    600
                );
                uint256 prNxt = TradeMath.tickToPr(step.tickNext);
                if (startPr <= prNxt) {
                    for (
                        uint i = cPr;
                        i <= (prNxt > endPr ? endPr : prNxt);
                        i++
                    ) {
                        liqL[i - startPr] = liq;
                        // console.log(">>> i: ", i - startPr, "---> Liq: ",liq);
                    }
                }
                if (step.initialized) {
                    (, int128 liquidityNet, , , ,  ) = IRoxSpotPool(spotPool)
                        .ticks(step.tickNext);
                    // if (zeroForOne) liquidityNet = - liquidityNet;
                    liq = LiquidityMath.addDelta(liq, -liquidityNet);
                }
                if (startPr <= prNxt && prNxt <= endPr) {
                    liqL[prNxt - startPr] = liq;
                }
                cPr = prNxt + 1;
                prState.tick = step.tickNext + 1;
                if (step.tickNext > TickMath.MAX_TICK) break;
            }
        } else if (endPr <= prState.prStart) {
            uint cPr = prState.prStart;
            // console.log(">>> cPr: ", cPr,"  startPr: ", startPr);
            TradeData.StepComputations memory step;
            while (cPr >= startPr) {
                (
                    step.tickNext,
                    step.initialized
                ) = nextInitializedTickWithinOneWord(
                    spotPool,
                    prState.tick,
                    true,
                    600
                );
                uint256 prNxt = TradeMath.tickToPr(step.tickNext);
                // TradeMath.printInt(">>> prState.tick : ", prState.tick);
                // TradeMath.printInt(">>> step.tickNext: ", step.tickNext);
                // console.log(">>> prNxt: ", prNxt);
                if (prNxt <= endPr) {
                    for (
                        uint i = (prNxt < startPr ? startPr : prNxt);
                        i <= (cPr > endPr ? endPr : cPr);
                        i++
                    ) {
                        liqL[i - startPr] = liq;
                        // console.log(">>> i: ", i - startPr, "---> Liq: ",liq);
                    }
                }
                if (step.initialized) {
                    (, int128 liquidityNet, , , , ) = IRoxSpotPool(spotPool)
                        .ticks(step.tickNext);
                    // if (zeroForOne) liquidityNet = - liquidityNet;
                    liq = LiquidityMath.addDelta(liq, liquidityNet);
                    // TradeMath.printInt(">>> liquidityNet : ", liquidityNet);
                }

                if (startPr <= prNxt && prNxt <= endPr) {
                    liqL[prNxt - startPr] = liq;
                }
                cPr = prNxt - 1;
                // console.log(">>> cPr: ", cPr);
                prState.tick = step.tickNext - 1;
                if (step.tickNext < TickMath.MIN_TICK) break;
            }
        } else {
            uint cPr = prState.prStart;
            TradeData.StepComputations memory step;
            while (cPr <= endPr) {
                (
                    step.tickNext,
                    step.initialized
                ) = nextInitializedTickWithinOneWord(
                    spotPool,
                    prState.tick,
                    false,
                    600
                );
                uint256 prNxt = TradeMath.tickToPr(step.tickNext);
                if (startPr <= prNxt) {
                    for (
                        uint i = cPr;
                        i <= (prNxt > endPr ? endPr : prNxt);
                        i++
                    ) {
                        liqL[i - startPr] = liq;
                        // console.log(">>> i: ", i - startPr, "---> Liq: ",liq);
                    }
                }
                if (step.initialized) {
                    (, int128 liquidityNet, , , , ) = IRoxSpotPool(spotPool)
                        .ticks(step.tickNext);
                    // if (zeroForOne) liquidityNet = - liquidityNet;
                    liq = LiquidityMath.addDelta(liq, -liquidityNet);
                }
                if (startPr <= prNxt && prNxt <= endPr) {
                    liqL[prNxt - startPr] = liq;
                }
                cPr = prNxt + 1;
                prState.tick = step.tickNext + 1;
                if (step.tickNext > TickMath.MAX_TICK) break;
            }
            cPr = prState.prStart;
            while (cPr >= startPr) {
                (
                    step.tickNext,
                    step.initialized
                ) = nextInitializedTickWithinOneWord(
                    spotPool,
                    prState.tick,
                    true,
                    600
                );
                uint256 prNxt = TradeMath.tickToPr(step.tickNext);
                // TradeMath.printInt(">>> prState.tick : ", prState.tick);
                // TradeMath.printInt(">>> step.tickNext: ", step.tickNext);
                // console.log(">>> prNxt: ", prNxt);
                if (prNxt <= endPr) {
                    for (
                        uint i = (prNxt < startPr ? startPr : prNxt);
                        i <= (cPr > endPr ? endPr : cPr);
                        i++
                    ) {
                        liqL[i - startPr] = liq;
                        // console.log(">>> i: ", i - startPr, "---> Liq: ",liq);
                    }
                }
                if (step.initialized) {
                    (, int128 liquidityNet, , , , ) = IRoxSpotPool(spotPool)
                        .ticks(step.tickNext);
                    // if (zeroForOne) liquidityNet = - liquidityNet;
                    liq = LiquidityMath.addDelta(liq, liquidityNet);
                    // TradeMath.printInt(">>> liquidityNet : ", liquidityNet);
                }

                if (startPr <= prNxt && prNxt <= endPr) {
                    liqL[prNxt - startPr] = liq;
                }
                cPr = prNxt - 1;
                // console.log(">>> cPr: ", cPr);
                prState.tick = step.tickNext - 1;
                if (step.tickNext < TickMath.MIN_TICK) break;
            }
        }
    }

    function getLiqs(
        address spotPool,
        int24 startPrTick,
        uint256 _resvAmount,
        bool is0
    )
        public
        view
        override
        returns (
            uint256[] memory liqL,
            uint256 liqSum,
            uint256 ltLiq,
            uint256 tkSum
        )
    {
        (int256[] memory liqMap, int24 _tickEnd) = getLiqDetails(
            spotPool,
            startPrTick,
            _resvAmount
        );
        int24 tickPrEnd = TradeMath.tickPoint(_tickEnd);

        if (is0) {
            require(tickPrEnd >= startPrTick, "x0");
            liqL = new uint256[](uint256((tickPrEnd - startPrTick) / 600 + 1));
            int24 tmpCr2 = 0;
            for (uint i = 0; i < liqL.length; i++) {
                for (int24 j = tmpCr2; j < int24(liqMap.length / 2 - 1); j++) {
                    // console.log("j :::: ", uint256(j));
                    // TradeMath.printInt("liqMap[j*2 + 1]", liqMap[j*2 + 1]);
                    // TradeMath.printInt("lbState.startPrTick + int256(i * 600)", bState.startPrTick + int256(i * 600));
                    if (
                        liqMap[uint(j * 2 + 1)] <= startPrTick + int256(i * 600)
                    ) {
                        tmpCr2 = j;
                    } else break;
                }
                liqL[i] = uint256(liqMap[uint24(tmpCr2 * 2)]);

                if (i == liqL.length - 1) {
                    ltLiq = FullMath.mulDiv(
                        liqL[i],
                        uint256(_tickEnd - tickPrEnd),
                        600
                    );
                    liqSum += ltLiq;
                    // liqL[i] = FullMath.mulDiv(liqL[i], uint256(bState.tickEnd - bState.tickPrEnd), 600);
                } else {
                    liqSum += liqL[i];
                }
            }
            // // console.log("start 333");
            // // TradeMath.printInt("bState.startPrTick:", bState.startPrTick);
            // // TradeMath.printInt("bState.tickEnd:", bState.tickEnd);
            // // TradeMath.printInt("bState.tickPrEnd:", bState.tickPrEnd);
            // // TradeMath.printInt("bState.prRange:", bState.prRange);
            // // console.log("liqL.length", liqL.length);
            require(liqSum > 0, "noliqSum");

            tmpCr2 = 0;
            for (uint i = 0; i < liqL.length; i++) {
                tkSum += uint256(
                    SqrtPriceMath.getAmount0Delta(
                        TickMath.getSqrtRatioAtTick(startPrTick + tmpCr2),
                        TickMath.getSqrtRatioAtTick(
                            startPrTick + (tmpCr2 += 600)
                        ),
                        int128(
                            FullMath.mulDiv(
                                liqL[0],
                                i == liqL.length - 1 ? ltLiq : liqL[i],
                                liqSum
                            )
                        )
                    )
                );
            }
        } else {
            require(tickPrEnd <= startPrTick, "x1");
            liqL = new uint256[](uint256((startPrTick - tickPrEnd) / 600 + 1));
            int24 tmpCr2 = 0;
            for (uint i = 0; i < liqL.length; i++) {
                for (int24 j = tmpCr2; j < int24(liqMap.length / 2 - 1); j++) {
                    // console.log("j :::: ", uint256(j));
                    // TradeMath.printInt("liqMap[j*2 + 1]", liqMap[j*2 + 1]);
                    // TradeMath.printInt("lbState.startPrTick + int256(i * 600)", bState.startPrTick + int256(i * 600));
                    if (
                        liqMap[uint(j * 2 + 1)] <= startPrTick - int256(i * 600)
                    ) {
                        tmpCr2 = j;
                    } else break;
                }
                liqL[i] = uint256(liqMap[uint(tmpCr2 * 2)]);

                if (i == liqL.length - 1) {
                    require(_tickEnd >= tickPrEnd, "tCc");
                    // TradeMath.printInt("_tickEnd  : ",  _tickEnd);
                    // TradeMath.printInt("tickPrEnd : ", tickPrEnd);
                    ltLiq = FullMath.mulDiv(
                        liqL[i],
                        uint256(600 - _tickEnd + tickPrEnd),
                        600
                    );
                    liqSum += ltLiq;
                } else {
                    liqSum += liqL[i];
                }
            }
            // // console.log("start 333");
            // // TradeMath.printInt("bState.startPrTick:", bState.startPrTick);
            // // TradeMath.printInt("bState.tickEnd:", bState.tickEnd);
            // // TradeMath.printInt("bState.tickPrEnd:", bState.tickPrEnd);
            // // TradeMath.printInt("bState.prRange:", bState.prRange);
            // // console.log("liqL.length", liqL.length);
            require(liqSum > 0, "noliqSum");
            tmpCr2 = 0;
            for (uint i = 0; i < liqL.length; i++) {
                tkSum += uint256(
                    SqrtPriceMath.getAmount0Delta(
                        TickMath.getSqrtRatioAtTick(startPrTick + tmpCr2),
                        TickMath.getSqrtRatioAtTick(
                            startPrTick + (tmpCr2 -= 600) + 1200
                        ),
                        int128(
                            FullMath.mulDiv(
                                liqL[0],
                                i == liqL.length - 1 ? ltLiq : liqL[i],
                                liqSum
                            )
                        )
                    )
                );
            }
        }
    }

    function token0t1NoSpl(
        address _spotPool,
        uint256 _amount0
    ) public view returns (uint256) {
        //test only, delete later
        //TODO: protect from flash attach
        //      as price is loaded from slot0
        (uint160 curPrice, , , , , , ) = IRoxSpotPool(_spotPool).slot0();
        return TradeMath.token0to1NoSpl(_amount0, uint256(curPrice));
    }

    function token1t0NoSpl(
        address _spotPool,
        uint256 _amount1
    ) public view returns (uint256) {
        //test only, delete later
        //TODO: protect from flash attach
        //      as price is loaded from slot0
        (uint160 curPrice, , , , , , ) = IRoxSpotPool(_spotPool).slot0();
        return TradeMath.token1to0NoSpl(_amount1, uint256(curPrice));
    }

    // Price Related functions
    function getClosePrice(
        address _spotPool,
        bool _long0,
        uint256 _sizeDelta
    ) public view override returns (uint256) {
        TradeData.TradePosition memory tP;
        tP.long0 = _long0;
        return gClosePrice(_spotPool, _sizeDelta, tP);
    }

    function getOpenPrice(
        address _roguPool,
        bool _long0,
        uint256 _sizeDelta
    ) public view override returns (uint256 openPrice) {
        (openPrice, , , ) = gOpenPrice(_roguPool, _long0, _sizeDelta);
    }

    function gOpenPrice(
        address _roguPool,
        bool _long0,
        uint256 _sizeDelta
    ) public view override returns (uint160, int24, uint160, int24) {
        TradeData.OpenPricState memory ops = _gOpenPrice(
            _roguPool,
            _long0,
            _sizeDelta
        );
        return (ops.openPrice, ops.openTick, ops.curPrice, ops.curTick);
    }

    function _gOpenPrice(
        address _roguPool,
        bool _long0,
        uint256 _sizeDelta
    ) private view returns (TradeData.OpenPricState memory ops) {
        address _spotPool = IRoxPerpPool(_roguPool).spotPool();
        ops.openPrice = getSqrtTwapX96(_spotPool);
        (ops.curPrice, ops.curTick, , , , , ) = IRoxSpotPool(_spotPool).slot0();

        // ATTENTION : TODO :
        // Protect from price/liquidity manipulation to reduce splitage
        //  Case 1 : swap - open - swap, move latest price to large liquidity range
        //  Case 2 : addLiquidity - open - removeLiquidity , lock&add coolDownTime ?

        if (_long0) {
            // uint256 _amounCt = globalLong0.add(_sizeDelta).div(2);
            (ops.sqrtPriceX96, , ) = estimate(
                _spotPool,
                !_long0,
                false,
                int256(
                    IRoxPerpPool(_roguPool).globalLong0().add(_sizeDelta).div(2)
                )
            );
            require(ops.sqrtPriceX96 >= ops.curPrice, "Open>P");
            ops.openPrice = ops.openPrice > ops.curPrice
                ? ops.openPrice
                : ops.curPrice;
            // openPrice += FullMath.mulDiv(openPrice, uint256(sqrtPriceX96 - curPrice), curPrice);
            ops.openPrice += ops.sqrtPriceX96 - ops.curPrice;
        } else {
            (ops.sqrtPriceX96, , ) = estimate(
                _spotPool,
                !_long0,
                false,
                int256(
                    IRoxPerpPool(_roguPool).globalLong1().add(_sizeDelta).div(2)
                )
            );
            require(ops.sqrtPriceX96 <= ops.curPrice, "Open<P");
            ops.openPrice = ops.openPrice < ops.curPrice
                ? ops.curPrice
                : ops.openPrice;

            // openPrice = openPrice - (curPrice - sqrtPriceX96);
            ops.openPrice =
                ops.openPrice -
                uint160(
                    FullMath.mulDiv(
                        ops.openPrice,
                        uint256(ops.curPrice - ops.sqrtPriceX96),
                        ops.curPrice
                    )
                ); //same
        }
        ops.openTick = TickMath.getTickAtSqrtRatio(ops.openPrice);
    }

    function countClose(
        address _perpPool,
        bool long0,
        uint32 minC
    ) public view returns (uint256 amount) {
        uint32 cur_c = uint32(block.timestamp.div(60));
        if (long0) {
            for (uint32 i = 0; i < minC + 1; i++) {
                amount = amount.add(
                    IRoxPerpPool(_perpPool).closeMinuteMap0(cur_c + i)
                );
            }
        } else {
            for (uint32 i = 0; i < minC + 1; i++) {
                amount = amount.add(
                    IRoxPerpPool(_perpPool).closeMinuteMap1(cur_c + i)
                );
            }
        }
    }

    function gClosePrice(
        address _roguPool,
        uint256 _sizeDelta,
        TradeData.TradePosition memory tP
    ) public view override returns (uint256) {
        address _spotPool = IRoxPerpPool(_roguPool).spotPool();
        uint256 closePrice = uint256(getSqrtTwapX96(_spotPool));
        {
            uint256 cCount = countClose(_roguPool, tP.long0, countMin);
            (uint160 curPrice, , , , , , ) = IRoxSpotPool(_spotPool).slot0();
            uint256 tPrice = getSqrtTwapX96(_spotPool);
            if (tP.long0) {
                uint256 countSize = _sizeDelta.div(2).add(cCount); //globalLong0.div(2)
                uint256 _splAmount = TradeMath.token1to0NoSpl(
                    countSize,
                    tPrice
                ); //GlobalLong0: amount of tk1
                (uint160 sqrtPriceX96est, , ) = estimate(
                    _spotPool,
                    tP.long0,
                    false,
                    int256(_splAmount)
                ); //
                require(sqrtPriceX96est < curPrice, "Close<P");
                closePrice = closePrice < curPrice ? closePrice : curPrice;
                uint256 s = 1e8;
                if (tP.size > 0) {
                    uint256 a = IRoxSpotPool(_spotPool).liqAccum0().sub(
                        uint256(tP.entryLiq0)
                    );
                    uint256 b = IRoxSpotPool(_spotPool).liqAccum1().sub(
                        uint256(tP.entryLiq1)
                    );
                    if (a > b && (uint256(tP.sizeLiquidity) < (a + b))) {
                        s = FullMath.mulDiv(
                            tP.sizeLiquidity,
                            _sizeDelta,
                            tP.size
                        );
                        s = FullMath.mulDiv(s, a - b, a + b).mul(1e4).div(
                            a + b
                        );
                        // unchecked {
                        uint256 _k = (kMax * 3000) /
                            IRoxSpotPool(_spotPool).fee();
                        // console.log(">>> k ", _k);
                        // console.log(">>> fee ", IRoxSpotPool(_spotPool).fee());
                        s = (s ** powF) * _k + 1e8;
                        // }
                    }
                }
                closePrice = closePrice.sub(
                    uint256(curPrice - sqrtPriceX96est).mul(s).div(1e8)
                );
            } else {
                uint256 countSize = _sizeDelta.div(2).add(cCount); //globalLong0.div(2)
                uint256 _splAmount = TradeMath.token0to1NoSpl(
                    countSize,
                    tPrice
                ); //GlobalLong0: amount of tk1
                (uint160 sqrtPriceX96est, , ) = estimate(
                    _spotPool,
                    tP.long0,
                    false,
                    int256(_splAmount)
                ); //
                require(sqrtPriceX96est > curPrice, "Close>P");
                closePrice = closePrice > curPrice ? closePrice : curPrice;
                uint256 s = 1e8;
                if (tP.size > 0) {
                    uint256 a = IRoxSpotPool(_spotPool).liqAccum0().sub(
                        uint256(tP.entryLiq0)
                    );
                    uint256 b = IRoxSpotPool(_spotPool).liqAccum1().sub(
                        uint256(tP.entryLiq1)
                    );
                    if (a < b && (uint256(tP.sizeLiquidity) < (a + b))) {
                        s = FullMath.mulDiv(
                            tP.sizeLiquidity,
                            _sizeDelta,
                            tP.size
                        );
                        s = FullMath.mulDiv(s, b - a, a + b).mul(1e4).div(
                            a + b
                        );
                        uint256 _k = (kMax * 3000) /
                            IRoxSpotPool(_spotPool).fee();
                        // console.log(">>> k ", _k);
                        // console.log(">>> fee ", IRoxSpotPool(_spotPool).fee());
                        s = (s ** powF) * _k + 1e8;
                    }
                }
                closePrice = closePrice.add(
                    uint256(sqrtPriceX96est - curPrice).mul(s).div(1e8)
                );
            }
        }
        return closePrice;
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



    // function updateFee(
    //     mapping(bytes32 => Position) storage self,
    //     address owner,
    //     int24 tickLower,
    //     int24 tickUpper,
    //     address roxPerpPool
    // ) external {

    //     bytes32 key = PositionKey.compute(
    //                     owner,
    //                     tickLower,
    //                     tickUpper
    //                 );
    //     RoxPosition.Position memory position = self[key];
        
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
    //             dCache.curTimeSlot = IRoxPerpPool(roxPerpPool).prUpdTime(prLoop/12);
    //             dCache.entryPriceSlot = position.priceMap[dCache.prId];
    //             dCache.prId += 1;
    //         }
    //         dCache.cPrice = TradeMath.priceInPs(dCache.entryPriceSlot, prLoop);
    //         //TODO: combine 0 & 1 to save gas
    //         dCache.entryTime = uint32(PriceRange.prTime(dCache.entryTimeSlot, prLoop));
    //         dCache.curTime = uint32(PriceRange.prTime(dCache.curTimeSlot, prLoop));

    //         //fee settle
    //         if (dCache.cPrice > 0) {
    //             PriceRange.Info memory prEntry = IRoxPerpPool(roxPerpPool).prInfo(PriceRange.prTimeId(prLoop, dCache.entryTime));
    //             PriceRange.Info memory prCur = IRoxPerpPool(roxPerpPool).prInfo(PriceRange.prTimeId(prLoop, dCache.curTime));
    //             uint256 entrySupLiq = uint256(position.liquidity) * 10000 / dCache.cPrice;
    //             position.spotFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee0X128, prCur.spotFee0X128);
    //             position.spotFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.spotFee1X128, prCur.spotFee1X128);
    //             position.perpFeeOwed0 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee0X128, prCur.perpFee0X128);
    //             position.perpFeeOwed1 += PriceRange.feeCollect(entrySupLiq, prEntry.perpFee1X128, prCur.perpFee1X128);           
    //         }
    //     } 

    //     // Update to latesr time slots
    //     position.timeMap = IRoxPerpPool(roxPerpPool).encodeTimeSlots(dCache.prStart, dCache.prEnd);
    //     self[key] = position;
    // }



}
