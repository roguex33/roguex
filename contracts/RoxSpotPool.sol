// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import "./interfaces/IRoxSpotPool.sol";
import "./NoDelegateCall.sol";
import "./libraries/LowGasSafeMath.sol";
import "./libraries/SafeCast.sol";
import "./libraries/Tick.sol";
import "./libraries/TickBitmap.sol";

import "./libraries/Oracle.sol";
import "./libraries/TradeMath.sol";
import "./libraries/RoxPosition.sol";
import "./libraries/PositionKey.sol";

import "./libraries/FullMath.sol";
import "./libraries/FixedPoint128.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/TickMath.sol";
import "./libraries/LiquidityMath.sol";
import "./libraries/SqrtPriceMath.sol";
import "./libraries/SwapMath.sol";
import "./libraries/PoolData.sol";

import "./interfaces/IRoxPosnPool.sol";
import "./interfaces/IRoxSpotPoolDeployer.sol";
import "./interfaces/IRoguexFactory.sol";
import "./interfaces/IERC20Minimal.sol";
import "./interfaces/callback/IMintCallback.sol";
import "./interfaces/callback/ISwapCallback.sol";
import "./interfaces/IRoxPerpPool.sol";
// import "hardhat/console.sol";

contract RoxSpotPool is IRoxSpotPool, NoDelegateCall {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Oracle for Oracle.Observation[65535];

    /// @inheritdoc IRoxSpotPoolImmutables
    address public immutable override factory;
    /// @inheritdoc IRoxSpotPoolImmutables
    address public immutable override token0;
    /// @inheritdoc IRoxSpotPoolImmutables
    address public immutable override token1;
    /// @inheritdoc IRoxSpotPoolImmutables
    uint24 public immutable override fee;

    int24 public constant override tickSpacing = 600;

    /// @inheritdoc IRoxSpotPoolImmutables
    uint128 public immutable override maxLiquidityPerTick;

    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }
    /// @inheritdoc IRoxSpotPoolState
    Slot0 public override slot0;

    /// @inheritdoc IRoxSpotPoolState
    uint128 public override liquidity;

    /// @inheritdoc IRoxSpotPoolState
    mapping(int24 => Tick.Info) public override ticks;

    /// @inheritdoc IRoxSpotPoolState
    mapping(int16 => uint256) public override tickBitmap;

    /// @inheritdoc IRoxSpotPoolState
    Oracle.Observation[65535] public override observations;

    address public override roxPerpPool;
    address public override roxPosnPool;

    uint256 public override l0rec;
    uint256 public override l1rec;

    uint256 public override liqAccum0;
    uint256 public override liqAccum1;

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
    /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
    modifier lock() {
        require(slot0.unlocked, "LOK");
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    modifier onlyPerpPool() {
        require(msg.sender == roxPerpPool, "xPP");
        _;
    }

    modifier onlyNftManager() {
        require(
            IRoguexFactory(factory).approvedNftRouters(msg.sender),
            "xMgr"
        );
        _;
    }


    constructor() {
        (factory, token0, token1, fee, ) = IRoxSpotPoolDeployer(msg.sender)
            .parameters();
        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(tickSpacing);
    }

    function positions(
        bytes32 key
    ) external  view override returns ( uint128 , uint256 , uint256 , uint128 , uint128 ){
        return IRoxPosnPool(roxPosnPool).positionsSum(key);
    }

    /// @dev Returns the block timestamp truncated to 32 bits, i.e. mod 2**32. This method is overridden in tests.
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    /// @dev Get the pool's balance of token0
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    function balance0() private view returns (uint256) {
        (bool success, bytes memory data) = token0.staticcall(
            abi.encodeWithSelector(
                IERC20Minimal.balanceOf.selector,
                address(this)
            )
        );
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @dev Get the pool's balance of token1
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) = token1.staticcall(
            abi.encodeWithSelector(
                IERC20Minimal.balanceOf.selector,
                address(this)
            )
        );
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @inheritdoc IRoxSpotPoolDerivedState
    function observe(
        uint32[] calldata secondsAgos
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
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );
    }

    /// @inheritdoc IRoxSpotPoolActions
    function increaseObservationCardinalityNext(
        uint16 observationCardinalityNext
    ) external override lock noDelegateCall {
        // TODO: temp. as contract size
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // for the event
        uint16 observationCardinalityNextNew = observations.grow(
            observationCardinalityNextOld,
            observationCardinalityNext
        );
        slot0.observationCardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(
                observationCardinalityNextOld,
                observationCardinalityNextNew
            );
    }

    /// @inheritdoc IRoxSpotPoolActions
    /// @dev not locked because it initializes unlocked
    function initialize(uint160 sqrtPriceX96) external override {
        require(slot0.sqrtPriceX96 == 0, "AI");

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(
            _blockTimestamp()
        );

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            feeProtocol: 0,
            unlocked: true
        });

        roxPerpPool = IRoguexFactory(factory).getTradePool(token0, token1, fee);
        roxPosnPool = IRoguexFactory(factory).getPositionPool(token0, token1, fee);
        emit Initialize(sqrtPriceX96, tick);
    }

    /// @dev Effect some changes to a position
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return amount0 the amount of token0 owed to the pool, negative if the pool should pay the recipient
    /// @return amount1 the amount of token1 owed to the pool, negative if the pool should pay the recipient
    function _modifyPosition(
        PoolData.ModifyPositionParams memory params
    )
        private
        noDelegateCall
        returns (
            // Position.Info storage position,
            uint256 amount0,
            uint256 amount1
        )
    {
        TickMath.checkTicks(params.tickLower, params.tickUpper);

        Slot0 memory _s0 = slot0;
        if (params.liquidityDelta < 1) {
            IRoxPosnPool(roxPosnPool).updateFee(
                PositionKey.compute(
                    params.owner,
                    params.tickLower,
                    params.tickUpper
                )
            );
        } else if (params.isBurn) {
            uint32[] memory pLst;
            (pLst, amount0, amount1) = IRoxPosnPool(roxPosnPool)
                .decreaseLiquidity(
                    PositionKey.compute(
                        params.owner,
                        params.tickLower,
                        params.tickUpper
                    ),
                    params.liquidityDelta,
                    _s0.tick,
                    _s0.sqrtPriceX96
                );
                
            {
                for (uint i = 0; i < pLst.length; i += 2) {
                    uint128 liqDelta = TradeMath.liqTrans(
                        params.liquidityDelta,
                        pLst[i],
                        pLst[i + 1]
                    );
                    _updateLiquidity(
                        params.tickLower,
                        (params.tickLower += 600),
                        -int128(liqDelta),
                        _s0.tick
                    );
                }
            }
        } else {
            IRoxPosnPool(roxPosnPool).increaseLiquidity(
                params.owner,
                params.tickLower,
                params.tickUpper,
                params.liquidityDelta
            );
            _updateLiquidity(
                params.tickLower,
                params.tickUpper,
                int128(params.liquidityDelta),
                _s0.tick
            );
            (amount0, amount1) = RoxPosition.getRangeToken(
                params.liquidityDelta,
                params.tickLower,
                params.tickUpper,
                _s0.tick,
                slot0.sqrtPriceX96
            );
        }

        if (amount0 > 0)
            l0rec = params.isBurn ? l0rec.sub(amount0) : l0rec.add(amount0);
        if (amount1 > 0)
            l1rec = params.isBurn ? l1rec.sub(amount1) : l1rec.add(amount1);

    }

    /// @dev Gets and updates a position with the given liquidity delta
    /// @ param owner the owner of the position
    /// @param tickLower the lower tick of the position's tick range
    /// @param tickUpper the upper tick of the position's tick range
    /// @param tick the current tick, passed to avoid sloads
    function _updateLiquidity(
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private {
        require(tickLower % 600 == 0 && tickUpper % 600 == 0, "t6");

        // if we need to update the ticks, do it
        bool flippedLower;
        bool flippedUpper;

        if (liquidityDelta != 0) {
            uint32 time = _blockTimestamp(); //TODO: timestamp as parameters
            (
                int56 tickCumulative,
                uint160 secondsPerLiquidityCumulativeX128
            ) = observations.observeSingle(
                    time,
                    0,
                    slot0.tick,
                    slot0.observationIndex,
                    liquidity,
                    slot0.observationCardinality
                );

            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                false,
                maxLiquidityPerTick
            );
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true,
                maxLiquidityPerTick
            );
            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }

            // uint128 liquidityBefore = liquidity; // SLOAD for gas optimization
            //// write an oracle entry
            // (slot0.observationIndex, slot0.observationCardinality) = observations.write(
            //     _slot0.observationIndex,
            //     _blockTimestamp(),
            //     _slot0.tick,
            //     liquidityBefore,
            //     _slot0.observationCardinality,
            //     _slot0.observationCardinalityNext
            // );

            liquidity = LiquidityMath.addDelta(liquidity, liquidityDelta);
        }

        // clear any tick data that is no longer needed
        if (liquidityDelta != 0) {
            if (ticks[tickLower].liquidityNet == 0) {
                ticks.clear(tickLower);
            }
            if (ticks[tickUpper].liquidityNet == 0) {
                ticks.clear(tickUpper);
            }
        }
    }


    /// @inheritdoc IRoxSpotPoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        require(amount > 0);
        (amount0, amount1) = _modifyPosition(
            PoolData.ModifyPositionParams({
                owner: recipient,
                tickLower: tickLower,
                tickUpper: tickUpper,
                isBurn: false,
                liquidityDelta: amount
            })
        );

        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        IMintCallback(msg.sender).mintCallback(
            amount0,
            amount1,
            data
        );

        if (amount0 > 0) {
            require(balance0Before.add(amount0) <= balance0(), "M0");
        }
        if (amount1 > 0) {
            require(balance1Before.add(amount1) <= balance1(), "M1");
        }
        emit Mint(
            msg.sender,
            recipient,
            tickLower,
            tickUpper,
            amount,
            amount0,
            amount1
        );
    }

    /// @inheritdoc IRoxSpotPoolActions
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        return _collect(msg.sender, recipient, tickLower, tickUpper, amount0Requested, amount1Requested);
    }

    function collectN(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock onlyNftManager returns (uint128 amount0, uint128 amount1) {
        return _collect(recipient, recipient, tickLower, tickUpper, amount0Requested, amount1Requested);
    }

    function _collect(
        address owner,
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) private returns (uint128 amount0, uint128 amount1) {
        // we don't need to checkTicks here, because invalid positions will never have non-zero tokensOwed{0,1}
        // RoxPosition.Position storage position = positions.get(msg.sender, tickLower, tickUpper);
        (amount0, amount1) = IRoxPosnPool(roxPosnPool).collect(
            PositionKey.compute(owner, tickLower, tickUpper),
            amount0Requested,
            amount1Requested
        );
        if (amount0 > 0) {
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }
        emit Collect(
            owner,
            recipient,
            tickLower,
            tickUpper,
            amount0,
            amount1
        );
    }



    /// @inheritdoc IRoxSpotPoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        return _burn(msg.sender, tickLower, tickUpper, amount);
    }

    function burnN(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external override lock onlyNftManager returns (uint256 amount0, uint256 amount1) {
        return _burn(owner, tickLower, tickUpper, amount);
    }

    function _burn(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) private returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _modifyPosition(
            PoolData.ModifyPositionParams({
                owner: owner,
                tickLower: tickLower,
                tickUpper: tickUpper,
                isBurn: true,
                liquidityDelta: amount
            })
        );
        uint256 liqdThres = IRoguexFactory(factory).liqdThres();
        (uint256 r0, uint256 r1) = availableReserve(true, true);
        require(r1 >= IRoxPerpPool(roxPerpPool).reserve1() * liqdThres / 1000, "0bn");
        require(r0 >= IRoxPerpPool(roxPerpPool).reserve0() * liqdThres / 1000, "1bn");
        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }


    // Only update recorded postion
    function updatePnl(
        int24 tickLower,
        int24 tickUpper,
        int24 slot0tick,
        int128 liquidityDelta
    ) external override onlyPerpPool {
        _updateLiquidity(
            tickLower,
            tickUpper,
            liquidityDelta,
            slot0tick
        );
    }

    function perpSettle(
        uint256 amount,
        bool is0,
        bool isBurn,
        address recipient
    )
        external
        override
        onlyPerpPool
    {
        if (amount < 1) return;

        if (is0) {
            if (isBurn) {
                l0rec -= amount;
                TransferHelper.safeTransfer(token0, recipient, amount);
            } else {
                l0rec += amount;
            }
        } else {
            if (isBurn) {
                l1rec -= amount;
                TransferHelper.safeTransfer(token1, recipient, amount);
            } else {
                l1rec += amount;
            }
        }
    }

    /// @inheritdoc IRoxSpotPoolActions
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    )
        external
        override
        noDelegateCall
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified != 0, "AS");

        Slot0 memory slot0Start = slot0;

        require(slot0Start.unlocked, "LOK");
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 &&
                    sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 &&
                    sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            "SPL"
        );

        slot0.unlocked = false;

        PoolData.SwapCache memory cache = PoolData.SwapCache({
            liquidityStart: liquidity,
            blockTimestamp: _blockTimestamp(),
            secondsPerLiquidityCumulativeX128: 0,
            tickCumulative: 0,
            computedLatestObservation: false
        });

        bool exactInput = amountSpecified > 0;

        PoolData.SwapState memory state = PoolData.SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0Start.sqrtPriceX96,
            tick: slot0Start.tick,
            feeGrowthGlobalX128: 0, //zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            liquidity: cache.liquidityStart
        });

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (
            state.amountSpecifiedRemaining != 0 &&
            state.sqrtPriceX96 != sqrtPriceLimitX96
        ) {
            PoolData.StepComputations memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) = tickBitmap
                .nextInitializedTickWithinOneWord(
                    state.tick,
                    tickSpacing,
                    zeroForOne
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

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            (
                state.sqrtPriceX96,
                step.amountIn,
                step.amountOut,
                step.feeAmount
            ) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (
                    zeroForOne
                        ? step.sqrtPriceNextX96 < sqrtPriceLimitX96
                        : step.sqrtPriceNextX96 > sqrtPriceLimitX96
                )
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            if (exactInput) {
                state.amountSpecifiedRemaining -= (step.amountIn +
                    step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated.sub(
                    step.amountOut.toInt256()
                );
            } else {
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated.add(
                    (step.amountIn + step.feeAmount).toInt256()
                );
            }

            // update global fee tracker
            if (state.liquidity > 0) {
                uint256 fpx = FullMath.mulDiv(
                    step.feeAmount,
                    FixedPoint128.Q128,
                    state.liquidity
                );
                IRoxPerpPool(roxPerpPool).updateSwapFee(state.tick, zeroForOne, fpx);
            }

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    // check for the placeholder value, which we replace with the actual value the first time the swap
                    // crosses an initialized tick
                    if (!cache.computedLatestObservation) {
                        (
                            cache.tickCumulative,
                            cache.secondsPerLiquidityCumulativeX128
                        ) = observations.observeSingle(
                            cache.blockTimestamp,
                            0,
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true;
                    }
                    int128 liquidityNet = ticks.cross(
                        step.tickNext,
                        cache.secondsPerLiquidityCumulativeX128,
                        cache.tickCumulative,
                        cache.blockTimestamp
                    );
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    if (zeroForOne) liquidityNet = -liquidityNet;

                    state.liquidity = LiquidityMath.addDelta(
                        state.liquidity,
                        liquidityNet
                    );
                }

                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // update tick and write an oracle entry if the tick change
        if (state.tick != slot0Start.tick) {
            (
                uint16 observationIndex,
                uint16 observationCardinality
            ) = observations.write(
                    slot0Start.observationIndex,
                    cache.blockTimestamp,
                    slot0Start.tick,
                    cache.liquidityStart,
                    slot0Start.observationCardinality,
                    slot0Start.observationCardinalityNext
                );
            (
                slot0.sqrtPriceX96,
                slot0.tick,
                slot0.observationIndex,
                slot0.observationCardinality
            ) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            // otherwise just update the price
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // update liquidity if it changed
        if (cache.liquidityStart != state.liquidity)
            liquidity = state.liquidity;

        (amount0, amount1) = zeroForOne == exactInput
            ? (
                amountSpecified - state.amountSpecifiedRemaining,
                state.amountCalculated
            )
            : (
                state.amountCalculated,
                amountSpecified - state.amountSpecifiedRemaining
            );


        // do the transfers and collect payment
        if (zeroForOne) {
            if (amount1 < 0) {
                TransferHelper.safeTransfer(
                    token1,
                    recipient,
                    uint256(-amount1)
                );
                l1rec = l1rec.sub(uint256(-amount1));
                l0rec = l0rec.add(
                    amount0 >= 0 ? uint256(amount0) : uint256(amount0)
                );
                int256 tkr = slot0Start.tick - slot0.tick;
                if (tkr > 0) {
                    liqAccum1 += uint256(
                        SqrtPriceMath.getLiquidityAmount1(
                            slot0Start.sqrtPriceX96,
                            slot0.sqrtPriceX96,
                            uint256(-amount1),
                            false
                        )
                    ).mul(uint256(tkr));
                }
            }
            uint256 balance0Before = balance0();
            ISwapCallback(msg.sender).swapCallback(
                amount0,
                amount1,
                data
            );
            require(balance0Before.add(uint256(amount0)) <= balance0(), "IIA");
        } else {
            if (amount0 < 0) {
                TransferHelper.safeTransfer(
                    token0,
                    recipient,
                    uint256(-amount0)
                );
                l0rec = l0rec.sub(uint256(-amount0));
                l1rec = l1rec.add(
                    amount1 >= 0 ? uint256(amount1) : uint256(amount1)
                );
                int256 tkr = slot0.tick - slot0Start.tick;
                if (tkr > 0) {
                    liqAccum0 += uint256(
                        SqrtPriceMath.getLiquidityAmount0(
                            slot0Start.sqrtPriceX96,
                            slot0.sqrtPriceX96,
                            uint256(-amount0),
                            false
                        )
                    ).mul(uint256(tkr));
                }
            }
            uint256 balance1Before = balance1();
            ISwapCallback(msg.sender).swapCallback(
                amount0,
                amount1,
                data
            );
            require(balance1Before.add(uint256(amount1)) <= balance1(), "IIA");
        }

        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            state.sqrtPriceX96,
            state.liquidity,
            state.tick
        );

        // zeroForOne: -true for token0 to token1, false for token1 to token0
        uint256 spotThres = IRoguexFactory(factory).spotThres();
        if (zeroForOne) { //token 1 decrease and only valid token 1
            (, uint256 r1) = availableReserve(false, true);
            require(r1 >= IRoxPerpPool(roxPerpPool).reserve1() * spotThres / 1000, "t1s");
        }
        else{
            (uint256 r0, ) = availableReserve(true, false);
            require(r0 >= IRoxPerpPool(roxPerpPool).reserve0() * spotThres / 1000, "t0s");
        }
        slot0.unlocked = true;
    }


    // function estimateDecreaseLiquidity(
    //     bytes32 _key,
    //     uint128 liquidityDelta
    // ) external view override returns (uint256 amount0, uint256 amount1) {
    //     return
    //         IRoxPosnPool(roxPosnPool).estimateDecreaseLiquidity(
    //             _key,
    //             liquidityDelta,
    //             slot0.tick,
    //             slot0.sqrtPriceX96
    //         );
    // }

    function availableReserve(
        bool _l0, bool _l1
        ) public view override returns (uint256 r0, uint256 r1){
        uint256 pr = TradeMath.tickToPr(slot0.tick);
        if (_l0){
            int256 curAmount = SqrtPriceMath.getAmount0Delta(
                    slot0.sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(TradeMath.prStartTick(pr + 1)),
                    int128(liquidity)
                );
            uint256 c0 = uint256(curAmount >= 0 ? curAmount : -curAmount);
            r0 = l0rec;
            r0 = r0 > c0 ? (r0 - c0) : 0;
        }
        if (_l1){
            int256 curAmount = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(TradeMath.prStartTick(pr)),
                    slot0.sqrtPriceX96,
                    int128(liquidity));
            uint256 c1 = uint256(curAmount >= 0 ? curAmount : -curAmount);
            r1 = l1rec;
            r1 = r1 > c1 ? (r1 - c1) : 0;
        }
    }
}
