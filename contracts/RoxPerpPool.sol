// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "./interfaces/IRoguexFactory.sol";
import "./interfaces/IRoxPerpPoolDeployer.sol";
import "./interfaces/IRoxSpotPool.sol";
import "./interfaces/IRoxPerpPool.sol";
import "./interfaces/IERC20Minimal.sol";
import './interfaces/external/IWETH9.sol';
import "./interfaces/IRoxUtils.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/TradeData.sol";
import "./libraries/TradeMath.sol";
import "./libraries/SafeCast.sol";
import "./libraries/Tick.sol";
import "./libraries/FullMath.sol";
import "./libraries/FixedPoint128.sol";
import "./libraries/TickMath.sol";
import "./libraries/SqrtPriceMath.sol";
import './libraries/PriceRange.sol';
import './libraries/PosRange.sol';

contract RoxPerpPool is IRoxPerpPool {
    // using SafeMath for uint256;
    // using SafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using PosRange for mapping(uint128 => uint256);
    using PriceRange for uint256[370];
    using PriceRange for mapping(uint256 => PriceRange.FeeInfo);

    event IncreasePosition(bytes32 key, address perpPool, address spotPool, uint256 sizeDelta, TradeData.TradePosition pos);
    event DecreasePosition(bytes32 key, address perpPool, address spotPool, uint256 sizeDelta, TradeData.TradePosition pos, bool isDel, uint160 closePrice);
    event CollectFee(uint256 fungdingFee, uint256 positionFee, uint256 feeDistribution, bool isToken0);
    event Liquidation(bytes32 key, bool hasProfit, uint256 profitDelta, uint256 fee);
    event Settle(bool burn, uint256 delta, uint256 fee);

    address public immutable factory;
    address public immutable weth;
    address public immutable override spotPool;
    address public immutable override token0;
    address public immutable override token1;

    IRoxUtils public roxUtils;

    TradeData.RoguFeeSlot rgFs;

    // uint256 public override globalLong0;
    // uint256 public override globalLong1;
    uint256 public override sBalance0;
    uint256 public override sBalance1;
    uint256 public override reserve0;
    uint256 public override reserve1;

    mapping(uint32 => int256) public override closeMinuteMap0;
    mapping(uint32 => int256) public override closeMinuteMap1;


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

    // Perp Position Storage, perpKey => position
    mapping(bytes32 => TradeData.TradePosition) perpPositions;


    // method split position into ranges
    mapping(uint128 => uint256) public posResv0;
    mapping(uint128 => uint256) public posResv1;
    // uint256[70] public l0activeMap;
    // uint256[70] public l1activeMap;
    // EnumerableSet.Bytes32Set l0pos;
    // EnumerableSet.Bytes32Set l1pos;

    constructor() {
        address _rUtils;
        address _factory;
        (
            _factory,
            token0,
            token1,
            ,
            ,
            spotPool,
            _rUtils
        ) = IRoxPerpPoolDeployer(msg.sender).parameters();
        roxUtils = IRoxUtils(_rUtils);
        rgFs = TradeData.RoguFeeSlot(
                    uint32(block.timestamp),
                    1,1,0,0);
        factory = _factory;
        weth = IRoguexFactory(_factory).weth();
    }
    function priceSlot(uint psId) external view override returns (uint256){
        return priceSlots.loadPriceslot(psId);
    }

    function rgFeeSlot(
    ) external override view returns (TradeData.RoguFeeSlot memory){
        return rgFs;
    }

    function prInfo(
        uint256 timePr
    ) external override view returns (PriceRange.FeeInfo memory){
        return prs[timePr];
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
        // uint256 fpx = FullMath.mulDiv(
        //         feeToken,
        //         FixedPoint128.Q128,
        //         uint256(liquidity).mul(PriceRange.PRP_PREC).div(price)  //change realLiq to sup Liq.
        //     )
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



    struct IncreaseCache{
        uint160 openPrice;
        int24 openTick;
        int24 curTick;
        uint32 curTime;
        uint160 curPrice;
        uint16 posId;
    }

    function increasePosition(
        address _account,
        uint256 _sizeDelta,
        bool _long0
        ) external override returns (bytes32, uint256) {
        _validSender(_account);

        bytes32 key = TradeMath.getPositionKey(_account, address(this), _long0);
        //> token0:p  token1:1/p
        TradeData.TradePosition memory position = perpPositions[key];
        IncreaseCache memory iCache;
        iCache.curTime = uint32(block.timestamp);

        // Long0:
        //  collateral & size: token1
        //  reserve & transferin : token0

        // uint256 iCache.curPrice = roxUtils.getSqrtTwapX96(spotPool, 3);
        (iCache.openPrice, iCache.openTick, iCache.curPrice, iCache.curTick) 
            = roxUtils.gOpenPrice(
                address(this),
                _sizeDelta,
                _long0, 
                false);

        // console.log("op: ", iCache.curPrice);
        // Update Collateral
        {
            //transfer in collateral is same as long direction
            uint256 tokenDelta = _transferIn(_long0);

            if (tokenDelta > 0){
                uint256 lR = tokenDelta * (95) / (100);
                position.transferIn += lR;
                position.liqResv += tokenDelta - lR;

                if (_long0){
                    uint256 _colDelta = TradeMath.token0to1NoSpl(lR, uint256(iCache.curPrice));
                    position.collateral = position.collateral + _colDelta;
                    //Temp. not used
                    // position.colLiquidity += SqrtPriceMath.getLiquidityAmount0(
                    //         iCache.openPrice, 
                    //         TickMath.getSqrtRatioAtTick( iCache.openTick - 10), 
                    //         _colDelta, false) * 10;
                }
                else{
                    uint256 _colDelta = TradeMath.token1to0NoSpl(lR, uint256(iCache.curPrice));
                    position.collateral = position.collateral + _colDelta;
                    // position.colLiquidity += SqrtPriceMath.getLiquidityAmount1(
                    //         iCache.openPrice, 
                    //         TickMath.getSqrtRatioAtTick( iCache.openTick + 10), 
                    //         _colDelta, false) * 10;
                }
                // console.log("II c", position.collateral, "tin",  tIn);
                // console.log(">t1: ",  position.transferIn);
                // console.log(">t2: ",  tokenDelta);
                // console.log(">c1: ",  tokenDelta);
            }
        }
        //Update price & time & entry liquidity
        {
            // init if need
            if (position.size == 0) {
                position.account = _account;
                position.long0 = _long0;    
                position.entrySqrtPriceX96 = iCache.openPrice;
                position.entryLiq0 = IRoxSpotPool(spotPool).liqAccum0();
                position.entryLiq1 = IRoxSpotPool(spotPool).liqAccum1();
                position.entryPos = PosRange.tickToPos(iCache.openTick);
                // _long0 ? l0pos.add(key) : l1pos.add(key);
            }
            else if (position.size > 0 && _sizeDelta > 0){
                
                // Update funding fee rate after reserve amount changed.
                {
                    // (uint64 acum0, uint64 acum1) = updateFundingRate();
                    uint64 curAcum = 
                                position.long0 ?
                                rgFs.fundFeeAccum0 + uint64(uint256(iCache.curTime - rgFs.time) * (uint256(rgFs.fundFee0)))
                                :
                                rgFs.fundFeeAccum1 + uint64(uint256(iCache.curTime - rgFs.time) * (uint256(rgFs.fundFee1)));
                    if (position.entryFdAccum > 0){
                        uint256 _ufee = FullMath.mulDiv(position.size, uint256(curAcum - position.entryFdAccum), 1e9);
                        require(position.collateral > _ufee, "uCol");
                        position.collateral -= _ufee;
                        position.uncollectFee += _ufee;
                    }
                    position.entryFdAccum = curAcum; 
                }
                
                position.entrySqrtPriceX96 = uint160(TradeMath.nextPrice(
                                position.size,
                                position.entrySqrtPriceX96,
                                iCache.openPrice,
                                _sizeDelta
                            ) );

                position.entryLiq0 = uint160(TradeMath.weightAve(
                                position.size,
                                position.entryLiq0,
                                _sizeDelta,
                                IRoxSpotPool(spotPool).liqAccum0()
                            ) );

                position.entryLiq1 = uint160(TradeMath.weightAve(
                                position.size,
                                position.entryLiq1,
                                _sizeDelta,
                                IRoxSpotPool(spotPool).liqAccum1()
                            ) );

                iCache.posId = PosRange.tickToPos(
                                    TickMath.getTickAtSqrtRatio(position.entrySqrtPriceX96));

                
                if (iCache.posId != position.entryPos){
                    position.long0 ? 
                        posResv0.posResvDelta(position.entryPos, position.reserve, false)
                        :
                        posResv1.posResvDelta(position.entryPos, position.reserve, false);

                    position.entryPos = iCache.posId;
                }
            }
            position.openSpread = TradeMath.spread(position.entrySqrtPriceX96, iCache.curPrice);
        }


        //update global and position reserve
        if(_sizeDelta > 0){
            _decreaseReserve(position.reserve, _long0);
            position.reserve = _long0 ? 
                    TradeMath.token1to0NoSpl(position.size + _sizeDelta, position.entrySqrtPriceX96)
                    :
                    TradeMath.token0to1NoSpl(position.size + _sizeDelta, position.entrySqrtPriceX96);
            _increaseReserve(position.reserve, _long0);
            if (position.long0){
                posResv0.posResvDelta(position.entryPos, position.reserve, true);
            }else{
                posResv1.posResvDelta(position.entryPos, position.reserve, true);
            }
            updateFundingRate(); //update funding rate after reserve changed.

        }


        //update Size
        if(_sizeDelta > 0){
            position.size = position.size + _sizeDelta;
            if (_long0){
                position.sizeLiquidity += SqrtPriceMath.getLiquidityAmount0(
                        iCache.openPrice, 
                        TickMath.getSqrtRatioAtTick(iCache.openTick - 10), //TODO: mWrite to save gas
                        _sizeDelta, false) * 10;
            }
            else{
                position.sizeLiquidity += SqrtPriceMath.getLiquidityAmount1(
                        iCache.openPrice, 
                        TickMath.getSqrtRatioAtTick(iCache.openTick + 10), //TODO: mWrite to save gas
                        _sizeDelta, false) * 10;
            }
            // //global update
            // if (_long0) {
            //     globalLong0 = globalLong0.add(_sizeDelta);
            // } else {
            //     globalLong1 = globalLong1.add(_sizeDelta);
            // }
        }

        roxUtils.validPosition(position.collateral, position.size);

        emit IncreasePosition(key, address(this), spotPool, _sizeDelta, position);


        perpPositions[key] = position;
        return (key, _long0 ? TradeMath.token1to0NoSpl(_sizeDelta, uint256(iCache.openPrice)) : _sizeDelta);
    }


    struct DecreaseCache{
        uint160 curPrice;
        // int24 closeTick;
        // int24 curTick;
        // uint32 curTime;
        bool del;
        bool isLiq;
        bool hasProfit;
        uint160 closePrice;
        uint256 payBack;
        uint256 payBackSettle;
        uint256 fee;
        uint256 feeDist;
        uint256 profitDelta;
        uint256 posFee;
    }

    function _validSender(address _owner) private view{
        require(msg.sender == _owner
                || IRoguexFactory(factory).approvedPerpRouters(msg.sender), "xSd");
    }

    function decreasePosition(
        bytes32 _key,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        address _feeRecipient,
        bool _toETH
    ) external override returns (bool, bool, uint256, address) {
        TradeData.TradePosition memory position = perpPositions[_key];
        DecreaseCache memory dCache;
        _validSender(position.account);

        if (_sizeDelta + _collateralDelta < 1)
            _sizeDelta = position.size;
        
        if (position.size == _sizeDelta){
            dCache.del = true;
            _collateralDelta = 0;
        }
        else if (_collateralDelta == position.collateral){
            _sizeDelta = position.size;
            _collateralDelta = 0;
            dCache.del = true;
        }
        else{
            require(_sizeDelta <= position.size, "ds" );
            require(_collateralDelta <= position.collateral, "dc" );
        }

        if (_feeRecipient == address(0))
            _feeRecipient = position.account;
        

        (dCache.closePrice, dCache.curPrice) = roxUtils.gClosePrice(
                        address(this),
                        _sizeDelta,
                        position,
                        false
                    );
        // collect funding fee and uncollect fee based on full position size
        {
            dCache.posFee = 
                position.long0 
                ?
                uint256(rgFs.fundFeeAccum0) + (block.timestamp - rgFs.time) * (uint256(rgFs.fundFee0))
                :
                uint256(rgFs.fundFeeAccum1) + (block.timestamp - rgFs.time) * (uint256(rgFs.fundFee1));

            // collect funding fee
            dCache.fee = FullMath.mulDiv(position.size, dCache.posFee - uint256(position.entryFdAccum), 1e9);

            position.entryFdAccum = uint64(dCache.posFee);
            // console.log("Fnd. Fee ", dCache.fee);
            // console.log("entry fdacum ",position.entryFdAccum);
           
            dCache.fee += position.uncollectFee;
            position.uncollectFee = 0;

            dCache.posFee = roxUtils.collectPosFee(position.size);
        }

        // Calculate PNL
        (dCache.hasProfit, dCache.profitDelta) = TradeMath.getDelta(
            position.long0,
            uint256(position.entrySqrtPriceX96),
            dCache.closePrice,
            position.size
        );        

        // Position validation
        {
            uint256 fullDec = dCache.fee + dCache.posFee + (dCache.hasProfit ? 0 : dCache.profitDelta);
            if (fullDec >= position.collateral){
                _sizeDelta = position.size;
                dCache.isLiq = true;
            }
            else if (fullDec + _collateralDelta > position.collateral){
                revert("dC");
            }
        }

        dCache.payBack = 0;//zero back to account
        if (dCache.isLiq){
            dCache.del = true;
            position.collateral = 0;
            _sizeDelta = position.size;
            _collateralDelta = 0;
            dCache.fee += dCache.posFee;
            emit Liquidation(_key, dCache.hasProfit, dCache.profitDelta, dCache.fee);
        }else{
        
            if (_sizeDelta < position.size){
                dCache.profitDelta = FullMath.mulDiv(_sizeDelta, dCache.profitDelta, position.size);
                dCache.posFee = FullMath.mulDiv(_sizeDelta, dCache.posFee, position.size);
            }
            dCache.fee += dCache.posFee;

            //collateral > fullDec + _collateralDelta as checked before.
            if (dCache.hasProfit){
                dCache.payBack += dCache.profitDelta;
                // force settle
                if (_feeRecipient != position.account){
                    dCache.payBackSettle = dCache.payBack / 10;
                    dCache.payBack -= dCache.payBackSettle ;
                }
            }else{
                position.collateral = position.collateral > dCache.profitDelta ?
                        position.collateral - dCache.profitDelta : 0;// size checked before
            }

            // settle fee
            position.collateral = position.collateral > dCache.fee ? 
                        position.collateral - dCache.fee : dCache.fee;// size checked before
            if (dCache.del){
                // pay remaining collateral back to trader
                _collateralDelta = position.collateral;
            }
            if (_collateralDelta > 0){
                require(position.collateral >=_collateralDelta, "neCol" );
                position.collateral = position.collateral - _collateralDelta;
                dCache.payBack += _collateralDelta;
            }
        }

        // valid max leverage
        if (position.collateral > 0){
            position.size = position.size - _sizeDelta;//check bef.
        }else{
            dCache.del = true;
            _sizeDelta = position.size;
        }

        if (!dCache.del)
            roxUtils.validPosition(position.collateral, position.size);


        // settle fee
        {
            // trans. to sameside token
            dCache.feeDist = position.long0 ? 
                TradeMath.token1to0NoSpl(dCache.fee, dCache.closePrice)
                : 
                TradeMath.token0to1NoSpl(dCache.fee, dCache.closePrice);
            emit CollectFee(dCache.fee, dCache.fee - dCache.posFee, dCache.feeDist, position.long0);
            if (dCache.feeDist > position.transferIn){
                dCache.feeDist = position.transferIn;
            }
            position.transferIn -= dCache.feeDist;//distribute fees to spot pool
        }

        // settle part Profit, Loss & Fees settlement
        {
            if (dCache.isLiq){
                // pay fee to liq. executor if position is liquidated
                position.long0 ? _transferOut0(position.liqResv, _feeRecipient, true) : _transferOut1(position.liqResv, _feeRecipient, true);
            }else if (dCache.del){
                // pay fee back to trader if not liquidated
                position.long0 ? _transferOut0(position.liqResv, position.account, _toETH) : _transferOut1(position.liqResv, position.account, _toETH);
                position.liqResv = 0; // can be ignored
            }

            uint256 withdrawFromPool = 0;
            if (dCache.payBack > 0) {
                dCache.payBack = position.long0
                    ? TradeMath.token1to0NoSpl(dCache.payBack, dCache.curPrice)
                    : TradeMath.token0to1NoSpl(dCache.payBack, dCache.curPrice);

                if (dCache.payBackSettle > 0){
                    dCache.payBackSettle = position.long0
                        ? TradeMath.token1to0NoSpl(dCache.payBackSettle, dCache.curPrice)
                        : TradeMath.token0to1NoSpl(dCache.payBackSettle, dCache.curPrice);
                    dCache.payBackSettle = position.transferIn > dCache.payBackSettle ?
                            dCache.payBackSettle
                            :
                            position.transferIn;

                    position.transferIn = position.transferIn - dCache.payBackSettle;
                    position.long0 ? _transferOut0(dCache.payBackSettle, _feeRecipient, true) : _transferOut1(dCache.payBackSettle, _feeRecipient, true);
                    dCache.payBackSettle = 0;
                }


                if (dCache.payBack <= position.transferIn){
                    position.transferIn = position.transferIn - dCache.payBack;
                    position.long0 ? _transferOut0(dCache.payBack, position.account, _toETH) : _transferOut1(dCache.payBack, position.account, _toETH);
                    dCache.payBack = 0;
                }
                else {
                    if (position.transferIn > 0){
                        dCache.payBack = dCache.payBack - position.transferIn;
                        position.long0 ? _transferOut0(position.transferIn, position.account, _toETH) : _transferOut1(position.transferIn, position.account, _toETH);
                        position.transferIn = 0;
                    }
                    withdrawFromPool = dCache.payBack;
                }
            }

            bool _withdraw = withdrawFromPool > 0;
            if (dCache.del && !_withdraw){
                // pay remain token to spotPool
                withdrawFromPool = position.transferIn;
            }
            settle(position.account, position.long0, _withdraw, withdrawFromPool, dCache.feeDist);
        }


        // Run after function settle() as reserved amount loaded in function settle()
        {
            uint256 _resvDelta = FullMath.mulDiv(position.reserve, _sizeDelta, position.size);
            position.reserve = position.reserve - _resvDelta;
            _decreaseReserve(_resvDelta, position.long0);        
        }

        // update funding fee rate
        updateFundingRate();

        address _acc = position.account;
        // Post-processing
        uint256 rtnDelta = position.long0 ? TradeMath.token1to0NoSpl(_sizeDelta, dCache.closePrice) : _sizeDelta;
        if (dCache.del){
            _delPosition(_key);
            // emit ClosePosition(key, position.account,
        }else{
            perpPositions[_key] = position;
        }
        emit DecreasePosition(_key, address(this), spotPool, _sizeDelta, position, dCache.del, dCache.closePrice);

        return (dCache.del, dCache.isLiq, rtnDelta, _acc);
    }


    //---------------------------------------- PRIVATE Functions --------------------------------------------------
    function _increaseReserve(uint256 _delta, bool _token0) private {
        // uint32 t = uint32(block.timestamp / 60);
        uint256 perpThres = IRoguexFactory(factory).perpThres();
        if (_token0) {
            reserve0 = reserve0 + _delta;
            (uint256 r0, ) = IRoxSpotPool(spotPool).availableReserve(true, false);
            require(r0 * perpThres >= reserve0 * 1000, "t0p");
            // closeMinuteMap0[t] -= int256(_delta);
        } else {
            reserve1 = reserve1 + _delta;
            (, uint256 r1) = IRoxSpotPool(spotPool).availableReserve(false,true );
            require(r1 * perpThres >= reserve1 * 1000, "t1p");
            // closeMinuteMap1[t] -= int256(_delta);
        }
    }

    function _decreaseReserve(uint256 _delta, bool _token0) private {
        uint32 t = uint32(block.timestamp / 60);
        if (_token0) {
            require(reserve0 >= _delta, "-0");
            reserve0 -= _delta;
            closeMinuteMap0[t] += int256(_delta);

        } else {
            require(reserve1 >= _delta, "-1");
            reserve1 -= _delta;
            closeMinuteMap1[t] += int256(_delta);
        }
    }

    function _delPosition(bytes32 _key) private {
        uint16 posId = perpPositions[_key].entryPos;

        perpPositions[_key].long0 ? 
            posResv0.posResvDelta(posId, perpPositions[_key].reserve, false)
            :
            posResv1.posResvDelta(posId, perpPositions[_key].reserve, false);
    
        delete perpPositions[_key];
    }


    function _transferIn(bool _isToken0) private returns (uint256) {
        if (_isToken0){
            uint256 prevBalance = sBalance0;
            sBalance0 = balance0();
            require(sBalance0 > prevBalance, "b0");
            return sBalance0 - prevBalance;
            // return sBalance0.sub(prevBalance, "sb0");
        }else{
            uint256 prevBalance = sBalance1;
            sBalance1 = balance1();
            require(sBalance1 > prevBalance, "b0");
            return sBalance1 - prevBalance;  
            // return sBalance1.sub(prevBalance, "sb1");
        }
    }

    function _transferOut0(uint256 _amount0, address _recipient, bool _toETH) private {
        if (_amount0 > 0){
            if (_toETH && token0 == weth){
                IWETH9(weth).withdraw(_amount0);
                TransferHelper.safeTransferETH(_recipient, _amount0);
            }else{
                TransferHelper.safeTransfer(token0, _recipient, _amount0);
            }
            sBalance0 = balance0();
        }
    }

    function _transferOut1(uint256 _amount1, address _recipient, bool _toETH) private {
        if (_amount1 > 0){
            if (_toETH && token1 == weth){
                IWETH9(weth).withdraw(_amount1);
                TransferHelper.safeTransferETH(_recipient, _amount1);
            }else{
                TransferHelper.safeTransfer(token1, _recipient, _amount1);
            }
            sBalance1 = balance1();
        }
    }

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

    function getPositionByKey(
        bytes32 _key
    ) public override view returns (TradeData.TradePosition memory) {
        return perpPositions[_key];
    }


    struct SettleCache{
        int24 tmpSht;
        int24 tickCur;
        int24 startTickRound;
        uint24 startPs;
        uint16 startPr;
        uint16 endPs;
        uint16 psId;
        uint16 prId;
        uint32 psTime;
        uint32 prCacheTime;
        uint32 curTime;
        //---slot----
        
        uint128 feeDt;
        uint128 feeCache;
        //---slot----

        uint256 endLiq;
        uint256 liqSum;
        uint256 curPriceSlot;
        uint256 curPrTimeSlot;
        uint256 resvCache;
    }



    function settle(
        address _recipient,
        bool _is0,
        bool _burn,
        uint256 _tokenAmount,
        uint256 _feeAmount
    ) internal {
        SettleCache memory bCache;
        // console.log("_feeAmount : ", _feeAmount);
        ( , bCache.tickCur , , , , , ) = IRoxSpotPool(spotPool).slot0();
        bCache.startTickRound = PriceRange.rightBoundaryTick(bCache.tickCur) - (_is0 ? 0 : 600);

        bCache.resvCache = _is0 ? reserve0 : reserve1;
        require(bCache.resvCache > 0 , "nRv");
        if (_burn)
            require(_tokenAmount <= bCache.resvCache, "lRv");
        uint256[] memory liqL;
        (liqL, bCache.endLiq, bCache.liqSum) = roxUtils.getLiquidityArraySpecifiedStart(
                    spotPool,
                    bCache.tickCur,
                    bCache.startTickRound,
                    _is0,
                    bCache.resvCache
                );
        require(liqL.length > 0, "tc");
        if (!_is0){
            bCache.startTickRound -= int24(liqL.length * 300);
        }

        (bCache.startPr, bCache.startPs) = PriceRange.tickTo(bCache.startTickRound);

        // bCache.endPs = uint16(PriceRange.prToPs(uint256(bCache.startPr) + liqL.length - 1));
        // TradeMath.printInt("Orig startTickRound  ", bCache.startTickRound);
        // console.log("  -----> PrRange : ", liqL.length);
        // console.log("startPr  ", bCache.startPr);
        // console.log("startPs  ", bCache.startPs, "--ToPs-->", bCache.endPs);
        
        bCache.curTime = uint32(block.timestamp);//uint256(block.timestamp).mul(PS_SPACING);
        // bCache.bOdd = bCache.startPr % 2 > 0;

        for(uint i = 0; i < liqL.length; i+=2){
            (bCache.prId, bCache.psId) = PriceRange.tickTo(bCache.startTickRound + bCache.tmpSht);
            uint128 liqDelta;
            if ( (_is0 && i+2 == liqL.length) || (!_is0 && i == 0)){
                liqDelta = uint128(FullMath.mulDiv(bCache.endLiq, _tokenAmount, bCache.resvCache));
                bCache.feeCache = uint128(FullMath.mulDiv(_feeAmount, bCache.endLiq, bCache.liqSum));
            }
            else{
                liqDelta = uint128(FullMath.mulDiv(liqL[i], _tokenAmount, bCache.resvCache));
                bCache.feeCache = uint128(FullMath.mulDiv(_feeAmount, liqL[i], bCache.liqSum));
            }
            // console.log("liqDelta : ", liqDelta);
            // console.log("endLiq   : ", bCache.endLiq);
            // console.log("oLiq: ",liqL[i]);

            if (bCache.curPriceSlot < 1){ 
                bCache.curPriceSlot = priceSlots.loadPriceslot(bCache.psId);
                bCache.curPrTimeSlot = timeSlots[bCache.psId];
                bCache.prCacheTime = PriceRange.prTime(bCache.curPrTimeSlot, bCache.prId);
            }

            //TODO:  combine update perpPositions with same liquidity to save gas
            // TradeMath.printInt("update Tick : ", bCache.startTickRound + bCache.tmpSht);

            // console.log(">>>>> Fee: ", _feeAmount, feeSum);
            // Update P.R in current P.S
            // uint32 priceL = bCache.psTime > 0 ? TradeMath.priceInPs(priceSlot[bCache.psTime + bCache.psId], bCache.psId) : 1e4;
            uint256 priceL = PriceRange.priceInPs(bCache.curPriceSlot, bCache.prId);
            // TradeMath.printInt("TickLeft ", bCache.startTickRound );

            // stop pnl update when price is too high or too low .
            // console.log(">>> Price:", uint256(priceL));
            if ( (priceL >= PriceRange.PRP_MAXP && !_burn)
                || (priceL <= PriceRange.PRP_MINP && _burn) ){
                uint128 _profit = uint128(FullMath.mulDiv(liqL[i+1], _tokenAmount, bCache.resvCache));
                require(_tokenAmount >= _profit, "tp");
                _tokenAmount -= _profit;
                // _tokenAmount = _tokenAmount.sub(_profit);   
                if (!_burn){
                    // do not update price
                    bCache.feeCache += _profit;
                    bCache.feeDt += _profit;
                }
                liqDelta = 0;
            }else{
                IRoxSpotPool(spotPool).updatePnl(
                    bCache.startTickRound + bCache.tmpSht, 
                    bCache.startTickRound + (bCache.tmpSht+= 600), 
                    bCache.tickCur,
                    _burn ? -int128(liqDelta) : int128(liqDelta));

                priceL = PriceRange.updatePrice(liqL[i], liqDelta, priceL, _burn);
                // console.log("       to  ------> ", uint256(priceL));
                bCache.curPriceSlot = PriceRange.updateU32Slot(bCache.curPriceSlot, bCache.prId, priceL);
            }

            // Fee Distribution is different from liq. dist.
            // TODO: already calculated in previous update price
            //       combine function variables to save gas.
            prs.updatePerpFee(
                bCache.prCacheTime,
                bCache.curTime,
                bCache.prId,
                priceL,
                _burn ? liqL[i] - liqDelta  : liqL[i] + liqDelta,
                bCache.feeCache,
                _is0);
            bCache.curPrTimeSlot = PriceRange.updateU32Slot(bCache.curPrTimeSlot, bCache.prId, bCache.curTime);

            //update current price slot if next cross or latest loop
            if (PriceRange.isRightCross(bCache.prId) || i == liqL.length -1){ 
                // console.log(">>> Update [pr]:", bCache.prId, "  >>> [ps]:", bCache.psId);
                priceSlots.writePriceSlot(bCache.psId, bCache.curPriceSlot);//sWrite to update
                timeSlots.writeTimeSlot(bCache.psId, bCache.curPrTimeSlot);
                bCache.curPriceSlot = 0;//renew pSlot
                // bCache.curPriceSlot = 0; //do not need reset
            } 
        }
        // console.log(">pF: ", _tokenAmount);
        _feeAmount += bCache.feeDt;
        if (_burn){
            _is0 ? _transferOut0(_feeAmount, spotPool, false) : _transferOut1(_feeAmount, spotPool, false);
        }
        else{
            _is0 ? _transferOut0(_tokenAmount + _feeAmount, spotPool, false) : _transferOut1(_tokenAmount + _feeAmount, spotPool, false);
        }
        IRoxSpotPool(spotPool).perpSettle(_tokenAmount, _is0, _burn, _recipient);
        emit Settle(_burn, _tokenAmount, _feeAmount);
        
    }

    function tPid(bool l0) public override view returns (uint256){
        return l0 ?
            posResv0.minPos()
            :
            posResv1.maxPos();
    }


    function updateFundingRate(
        ) public override returns (uint64, uint64) {
        uint256 curT = block.timestamp;
        uint256 tGap = curT - uint256(rgFs.time);
        if (tGap > 0){
            uint256 l0rec = IRoxSpotPool(spotPool).l0rec();
            uint256 l1rec = IRoxSpotPool(spotPool).l1rec();
            uint256 fdps = roxUtils.fdFeePerS();

            rgFs.fundFeeAccum0 += uint64(tGap*(uint256(rgFs.fundFee0)));
            rgFs.fundFeeAccum1 += uint64(tGap*(uint256(rgFs.fundFee1)));

            rgFs.fundFee0 = uint32(l0rec > 0 ? FullMath.mulDiv(reserve0, fdps, l0rec) : 0);
            rgFs.fundFee1 = uint32(l1rec > 0 ? FullMath.mulDiv(reserve1, fdps, l1rec) : 0);
            rgFs.time = uint32(curT);
        }
        return  (rgFs.fundFeeAccum0, rgFs.fundFeeAccum1);
    }
}
