// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import "./base/BlastBase.sol";
import "./NoDelegateCall.sol";
import "./libraries/LowGasSafeMath.sol";
import "./libraries/SafeCast.sol";
import "./libraries/Tick.sol";
import "./libraries/TickBitmap.sol";
import "./libraries/Oracle.sol";
import "./libraries/RoxPosition.sol";
import "./libraries/PositionKey.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/TickMath.sol";
import "./libraries/LiquidityMath.sol";
import "./libraries/SqrtPriceMath.sol";
import "./libraries/SwapMath.sol";
import "./libraries/PoolData.sol";
import "./libraries/TickRange.sol";

import "./interfaces/IRoxSpotPool.sol";
import "./interfaces/IRoxPosnPool.sol";
import "./interfaces/IRoxSpotPoolDeployer.sol";
import "./interfaces/IRoguexFactory.sol";
import "./interfaces/IERC20Minimal.sol";
import "./interfaces/callback/IMintCallback.sol";
import "./interfaces/callback/ISwapCallback.sol";
import "./interfaces/IRoxPerpPool.sol";
import "./interfaces/IRoxUtils.sol";

contract RoxSpotPool is IRoxSpotPool, NoDelegateCall, BlastBase {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    // using Oracle for Oracle.Observation[65535];

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
    uint128 public constant override maxLiquidityPerTick = 115076891079113447231442207450716337;//constant for 600 tickspace

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

    /// inheritdoc IRoxSpotPoolState
    // Oracle.Observation[65535] public override observations;

    address public immutable override roxPerpPool;
    address public immutable override roxPosnPool;
    address public immutable roxUtils;

    // uint256 public override l0rec;
    // uint256 public override l1rec;

    uint256 public override tInAccum0;
    uint256 public override tInAccum1;

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
        require(msg.sender == roxPerpPool, "xp");
        _;
    }

    constructor() {
        (factory, token0, token1, fee, roxPerpPool, roxPosnPool, roxUtils) = IRoxSpotPoolDeployer(msg.sender)
            .parameters();
        // maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(tickSpacing);
    }

    /// @dev Returns the block timestamp truncated to 32 bits, i.e. mod 2**32. This method is overridden in tests.
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    /// @dev Get the pool's balance of token0
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    function balance0() public override view returns (uint256) {
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
    function balance1() public override view returns (uint256) {
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
        return IRoxPosnPool(roxPosnPool).observe(
                // _blockTimestamp(),
                secondsAgos,
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );
            // observations.observe(
            //     _blockTimestamp(),
            //     secondsAgos,
            //     slot0.tick,
            //     slot0.observationIndex,
            //     liquidity,
            //     slot0.observationCardinality
            // );
    }

    // /// @inheritdoc IRoxSpotPoolActions
    // function increaseObservationCardinalityNext(
    //     uint16 observationCardinalityNext
    // ) external override lock noDelegateCall {
    //     uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // for the event
    //     uint16 observationCardinalityNextNew = observations.grow(
    //         observationCardinalityNextOld,
    //         observationCardinalityNext
    //     );
    //     slot0.observationCardinalityNext = observationCardinalityNextNew;
    //     if (observationCardinalityNextOld != observationCardinalityNextNew)
    //         emit IncreaseObservationCardinalityNext(
    //             observationCardinalityNextOld,
    //             observationCardinalityNextNew
    //         );
    // }

    /// @inheritdoc IRoxSpotPoolActions
    /// @dev not locked because it initializes unlocked
    function initialize(uint160 sqrtPriceX96) external override {
        require(slot0.sqrtPriceX96 == 0, "ai");

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        // (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(
        //     _blockTimestamp()
        // );
        (uint16 cardinality, uint16 cardinalityNext) = IRoxPosnPool(roxPosnPool).initializeObserve();

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            feeProtocol: 0,
            unlocked: true
        });
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
        uint32 time = _blockTimestamp(); 

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
            uint128[] memory liqDeltaArray;
            (liqDeltaArray, amount0, amount1) = IRoxPosnPool(roxPosnPool)
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
                for (uint i = 0; i < liqDeltaArray.length; i++) {
                    _updateLiquidity(
                        params.tickLower,
                        (params.tickLower += 600),
                        -int128(liqDeltaArray[i]),
                        _s0.tick,
                        time
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
                _s0.tick,
                time
            );
            (amount0, amount1) = RoxPosition.getRangeToken(
                params.liquidityDelta,
                params.tickLower,
                params.tickUpper,
                _s0.tick,
                slot0.sqrtPriceX96,
                true
            );
        }
        // if (amount0 > 0)
        //     l0rec = params.isBurn ? l0rec.sub(amount0) : l0rec.add(amount0);
        // if (amount1 > 0)
        //     l1rec = params.isBurn ? l1rec.sub(amount1) : l1rec.add(amount1);

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
        int24 tick,
        uint32 time
    ) private {
        if (liquidityDelta == 0)
            return;
        
        require(tickLower % 600 == 0 && tickUpper % 600 == 0 && tickLower < tickUpper, "t6");

        // if we need to update the ticks, do it
        bool flippedLower;
        bool flippedUpper;
        (
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128
        ) = IRoxPosnPool(roxPosnPool).observeSingle(
                time,
                // 0,
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );

        // (
        //     int56 tickCumulative,
        //     uint160 secondsPerLiquidityCumulativeX128
        // ) = observations.observeSingle(
        //         time,
        //         0,
        //         slot0.tick,
        //         slot0.observationIndex,
        //         liquidity,
        //         slot0.observationCardinality
        //     );

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
        if (tickLower <= slot0.tick && tickUpper > slot0.tick ){
            liquidity = LiquidityMath.addDelta(liquidity, liquidityDelta);
        }
    
        // clear any tick data that is no longer needed
        if (ticks[tickLower].liquidityNet == 0) {
            ticks.clear(tickLower);
        }
        if (ticks[tickUpper].liquidityNet == 0) {
            ticks.clear(tickUpper);
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
        return _mint(recipient, tickLower, tickUpper, amount, data);
    }

    function _mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes memory data
    ) private returns (uint256 amount0, uint256 amount1) {
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
            require(balance0Before.add(amount0) <= balance0(), "m0");
        }
        if (amount1 > 0) {
            require(balance1Before.add(amount1) <= balance1(), "m1");
        }
        IRoxPerpPool(roxPerpPool).updateFundingRate();

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
        address owner = recipient;
        if (!IRoguexFactory(factory).approvedNftRouters(msg.sender)){
            owner = msg.sender;     
            recipient = msg.sender;
        }
        else{//sender is NFTRouter
            owner = recipient;
            recipient = msg.sender; //token back to nft router
        }
        return _collect(owner, recipient, tickLower, tickUpper, amount0Requested, amount1Requested);
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
            uint128 b0 = uint128(balance0());
            if (amount0 > b0) amount0 = b0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            uint128 b1 = uint128(balance1());
            if (amount1 > b1) amount1 = b1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }
        IRoxPerpPool(roxPerpPool).updateFundingRate();
        emit Collect(
            owner,
            recipient,
            tickLower,
            tickUpper,
            amount0,
            amount1
        );
    }

    function burnN(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        if (!IRoguexFactory(factory).approvedNftRouters(msg.sender))
            owner = msg.sender;
        (amount0, amount1) = _burn(owner, tickLower, tickUpper, amount);
        if (msg.sender != IRoguexFactory(factory).spotHyper(address(this)))
            liqdCheck();
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

        IRoxPerpPool(roxPerpPool).updateFundingRate();
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
            slot0tick,
            _blockTimestamp()
        );
    }
    
    function perpSettle(
        uint256 amount,
        bool is0,
        address recipient
    )
        external
        override
        lock
        onlyPerpPool
    {
        if (amount < 1) return;
        TransferHelper.safeTransfer(is0 ? token0 : token1, recipient, amount);
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
            feeGrowth: 0,
            liquidity: cache.liquidityStart
        });

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (
            state.amountSpecifiedRemaining != 0 &&
            state.sqrtPriceX96 != sqrtPriceLimitX96
        ) {
            PoolData.StepComputations memory step;
            require(state.liquidity > 0, "ISL");

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) = tickBitmap
                .nextInitializedTickWithinOneWord(
                    state.tick,
                    tickSpacing,
                    zeroForOne
                );
            if (zeroForOne) {// 0 to 1, price <---- 
                if (state.tick - step.tickNext > 600) {
                    step.tickNext = TickRange.leftBoundaryTickWithin(state.tick);
                    step.initialized = false;
                }

            } else {//1 to 0, price ---->
                if (step.tickNext - state.tick > 600) {
                    step.tickNext = TickRange.rightBoundaryTick(state.tick);
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
            state.feeGrowth += uint128(step.feeAmount);
            // update global fee tracker
            if (state.liquidity > 0 && step.feeAmount > 0) {
                IRoxPosnPool(roxPosnPool).updateSwapFee(state.tick, zeroForOne, step.feeAmount, state.liquidity);
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
                        ) = IRoxPosnPool(roxPosnPool).observeSingle(
                            cache.blockTimestamp,
                            // 0,
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        // (
                        //     cache.tickCumulative,
                        //     cache.secondsPerLiquidityCumulativeX128
                        // ) = observations.observeSingle(
                        //     cache.blockTimestamp,
                        //     0,
                        //     slot0Start.tick,
                        //     slot0Start.observationIndex,
                        //     cache.liquidityStart,
                        //     slot0Start.observationCardinality
                        // );
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
            if (zeroForOne)
                require(slot0Start.tick > state.tick, "s0");
            else {
                require(slot0Start.tick < state.tick, "s1");
            }
            (
                uint16 observationIndex,
                uint16 observationCardinality
            ) = IRoxPosnPool(roxPosnPool).writeObserve(
                    slot0Start.observationIndex,
                    cache.blockTimestamp,
                    slot0Start.tick,
                    cache.liquidityStart,
                    slot0Start.observationCardinality,
                    slot0Start.observationCardinalityNext
                );
            // (
            //     uint16 observationIndex,
            //     uint16 observationCardinality
            // ) = observations.write(
            //         slot0Start.observationIndex,
            //         cache.blockTimestamp,
            //         slot0Start.tick,
            //         cache.liquidityStart,
            //         slot0Start.observationCardinality,
            //         slot0Start.observationCardinalityNext
            //     );
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
        uint256 spotThres = IRoxUtils(roxUtils).spotThres(address(this));
        if (zeroForOne) {
            if (amount1 < 0) {
                require(amount0 > 0, "a0");
                tInAccum0 = tInAccum0.add(uint256(amount0)).sub(uint256(state.feeGrowth));

                TransferHelper.safeTransfer(
                        token1,
                        recipient,
                        uint256(-amount1)
                    );

                (, uint256 r1) = IRoxUtils(roxUtils).availableReserve(address(this), false, true);
                require(r1 * spotThres  >= IRoxPerpPool(roxPerpPool).reserve1() * 1000, "z0");
                uint256 balance0Before = balance0();
                ISwapCallback(msg.sender).swapCallback(
                    amount0,
                    amount1,
                    data
                );
                require(balance0Before.add(uint256(amount0)) <= balance0(), "IIA");
            }

        } else {
            if (amount0 < 0) {
                require(amount1 > 0, "a1");
                tInAccum1 = tInAccum1.add(uint256(amount1));

                TransferHelper.safeTransfer(
                    token0,
                    recipient,
                    uint256(-amount0)
                );
                (uint256 r0, ) = IRoxUtils(roxUtils).availableReserve(address(this), true, false);
                require(r0  * spotThres >= IRoxPerpPool(roxPerpPool).reserve0() * 1000, "z1");
                uint256 balance1Before = balance1();
                ISwapCallback(msg.sender).swapCallback(
                    amount0,
                    amount1,
                    data
                );
                require(balance1Before.add(uint256(amount1)) <= balance1(), "IIA");
            }
        }
        require(state.liquidity > 0, "IS");
        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            state.sqrtPriceX96,
            state.liquidity,
            state.tick
        );
        
        IRoxPerpPool(roxPerpPool).updateFundingRate();
        slot0.unlocked = true;
    }

    // function availableReserve(
    //     bool _l0, bool _l1
    //     ) public view override returns (uint256 r0, uint256 r1){
    //         return IRoxUtils(roxUtils).availableReserve(address(this), _l0, _l1);
    // }

    function liqdCheck( ) public view returns (bool){
        uint256 liqdThres = IRoxUtils(roxUtils).spotThres(address(this));
        (uint256 r0, uint256 r1) = IRoxUtils(roxUtils).availableReserve(address(this), true, true);
        require(r1 * liqdThres>= IRoxPerpPool(roxPerpPool).reserve1() * 1000, "bn0");
        require(r0 * liqdThres>= IRoxPerpPool(roxPerpPool).reserve0() * 1000, "bn1");
        return true;
    }
    
    // function getTwapTickUnsafe(uint32 _sec) public view override returns (int24 tick) {   
    //     return IRoxUtils(roxUtils).getTwapTickUnsafe(address(this), _sec);
    // }
}
