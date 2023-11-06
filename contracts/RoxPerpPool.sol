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

import "./interfaces/IRoxUtils.sol";

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
import './libraries/PriceRange.sol';
import './libraries/PosRange.sol';

contract RoxPerpPool is IRoxPerpPool {
    using SafeMath for uint256;
    using SafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using PosRange for mapping(uint128 => uint256);
    using TradeMath for uint256[247];
    using TradeMath for uint256[70];
    using PriceRange for uint256[247];
    using PriceRange for mapping(uint256 => PriceRange.Info);

    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableValues for EnumerableSet.Bytes32Set;

    event IncreasePosition(bytes32 key, address tradePool, address spotPool, uint256 sizeDelta, TradeData.TradePosition pos);
    event DecreasePosition(bytes32 key, address tradePool, address spotPool, uint256 sizeDelta, TradeData.TradePosition pos);

    uint256 public constant RATIO_PREC = 1e6;
    uint256 public constant MAX_LEVERAGE = 80;

    address public immutable factory;
    address public immutable override spotPool;
    address public immutable override token0;
    address public immutable override token1;

    IRoxUtils public roxUtils;

    TradeData.RoguFeeSlot rgFs;

    uint256 public override globalLong0;
    uint256 public override globalLong1;
    uint256 public override sBalance0;
    uint256 public override sBalance1;
    uint256 public override reserve0;
    uint256 public override reserve1;

    mapping(uint32 => uint256) public override closeMinuteMap0;
    mapping(uint32 => uint256) public override closeMinuteMap1;


    // Price related.
    // Price Range:
    //      priceRangeId = (curTick + 887272)/600; NameAs => pr /@ max value = 887272 * 2(1774544Ticks) / 600 = 2958 PriceRanges
    // Price Slot:
    //      every 12 price Range(21bitPerId) stored in one uint256 slot,
    //      psId : 0 ~ 246      (2958 / 12 = 247)
    //      price Tick SlotId = priceRangeId / 12; 
    //      update time: u32,
    //  Only use bit 255 ---> 9 -xxxx-> 0, Bits used from high to low 
    uint256[247] public pSlots;

    // Store the latest update time of 185 price slots
    //      Each u256 contains 8 price slot times, (u32 * 8)
    // P.R Time Init map, range start = 1, =0 else
    // uint256 public override prInitMap;
    // P.R update time, 12 price range update time saved in one uint256
    // 2 price range share one time, i.e. each u256 contains 6 timestamp wit each 42bit
    uint256[247] public override prUpdTime;  

    mapping(uint256 => PriceRange.Info) public prs;

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
        (
            factory,
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
    }
    function priceSlot(uint psId) external view override returns (uint256){
        return pSlots.loadPs(psId);
    }

    function rgFeeSlot(
    ) external override view returns (TradeData.RoguFeeSlot memory){
        return rgFs;
    }

    function prInfo(
        uint256 timePr
    ) external override view returns (PriceRange.Info memory){
        return prs[timePr];
    }

    function updateSwapFee(
        int24 tick,
        bool zeroForOne,
        uint256 feeX128
    ) external override {
        require(msg.sender == spotPool);
        uint256 pr = PriceRange.tickToPr(tick);
        uint256 price = pSlots.loadPrPrice(pr);
        uint256 slotCache = prUpdTime[pr / 12];
        uint256 cacheTime = PriceRange.prTime(slotCache, pr);
        uint256 curTime = block.timestamp;
        // TradeMath.printInt("TICK: ", tick);
        // console.log(">SF :", feeX128);
        if (price < 1)
            return;
        // recalculate fee according to supply-liquidity  
        prs.updateSpotFee(cacheTime, curTime, pr, zeroForOne, uint128(feeX128 * 10000 / price) );

        prUpdTime[pr / 12] = PriceRange.updatePrTime(slotCache, pr, curTime);

        updateFundingRate();
    }

    // function prPrice(
    //     uint pr
    //     ) public override view returns (uint256){
    //     return pSlots.loadPrPrice(pr);
    // }
    
    function encodePriceSlots(
        uint256 prStart, uint256 prEnd
        ) public override view returns (uint256[] memory s) {
        return pSlots.prArray(prStart, prEnd);
    }
    
    function encodeTimeSlots(
        uint256 prStart, uint256 prEnd
        ) public override view returns (uint256[] memory s) {
        return prUpdTime.prArray(prStart, prEnd);
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
        // Long0:
        //  collateral & size: token1
        //  reserve & transferin : token0
        require(position.size.add(_sizeDelta) > 0, "ep");

        // uint256 iCache.curPrice = roxUtils.getSqrtTwapX96(spotPool, 3);
        // uint160 openPrice = uint160(getOpenPrice(_long0, _sizeDelta));
        (iCache.openPrice, iCache.openTick, iCache.curPrice, iCache.curTick) = roxUtils.gOpenPrice(address(this), _long0, _sizeDelta);

        // Update Collateral
        {
            //transfer in collateral is same as long direction
            uint256 tokenDelta = _transferIn(_long0);

            if (tokenDelta > 0){
                uint256 lR = tokenDelta.mul(95).div(100);
                position.transferIn += lR;
                position.liqResv += tokenDelta - lR;

                if (_long0){
                    uint256 _colDelta = TradeMath.token0to1NoSpl(lR, uint256(iCache.curPrice));
                    position.collateral = position.collateral.add(_colDelta);
                    //Temp. not used
                    // position.colLiquidity += SqrtPriceMath.getLiquidityAmount0(
                    //         iCache.openPrice, 
                    //         TickMath.getSqrtRatioAtTick( iCache.openTick - 10), 
                    //         _colDelta, false) * 10;
                }
                else{
                    uint256 _colDelta = TradeMath.token1to0NoSpl(lR, uint256(iCache.curPrice));
                    position.collateral = position.collateral.add(_colDelta);
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
            iCache.curTime = uint32(block.timestamp);
            // init if need
            if (position.size == 0) {
                position.account = _account;
                position.long0 = _long0;    
                position.positionTime = iCache.curTime;
                position.entrySqrtPriceX96 = iCache.openPrice;
                // position.entryLiq0 = IRoxSpotPool(spotPool).liqAccum0();
                // position.entryLiq1 = IRoxSpotPool(spotPool).liqAccum1();

                position.entryPos = TradeMath.tickToPos(iCache.openTick);
                // _long0 ? l0pos.add(key) : l1pos.add(key);

            }
            else if (position.size > 0 && _sizeDelta > 0){
                position.positionTime = uint32(TradeMath.nextPositionTime(
                                uint256(position.positionTime),
                                position.size,
                                iCache.curTime,
                                _sizeDelta
                            ));
                
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

                iCache.posId = TradeMath.tickToPos(
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
        }




        // Update funding fee rate after reserve amount changed.
        {
            (uint64 acum0, uint64 acum1) = updateFundingRate();
            if (position.entryFdAccum > 0){
                uint256 _ufee = position.size.mul( uint256((position.long0 ? acum0 : acum1) - position.entryFdAccum) ).div(1000000);
                require(position.collateral > _ufee, "uCol");
                position.collateral -= _ufee;
                position.uncollectFee += _ufee;
            }
            position.entryFdAccum = position.long0 ? acum0 : acum1; 
        }

        //update Size
        if(_sizeDelta > 0){
            position.size = position.size.add(_sizeDelta);
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
            require(position.size < position.collateral.mul(MAX_LEVERAGE), "mLvg");

            //global update
            if (_long0) {
                globalLong0 = globalLong0.add(_sizeDelta);
            } else {
                globalLong1 = globalLong1.add(_sizeDelta);
            }
        }

        _validatePosition(position.size, position.collateral);

        emit IncreasePosition(key, address(this), spotPool, _sizeDelta, position);

        perpPositions[key] = position;
        // if (!positionKeys[_account].contains(key))
            // positionKeys[_account].add(key);

        return (key, _long0 ? TradeMath.token1to0NoSpl(_sizeDelta, uint256(iCache.openPrice)) : _sizeDelta);
    }


    struct DecreaseCache{
        uint160 curPrice;
        int24 closeTick;
        int24 curTick;
        uint32 curTime;
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
        address _feeRecipient
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
        }

        if (_feeRecipient == address(0))
            _feeRecipient = position.account;
        
      
        dCache.closePrice = uint160(roxUtils.gClosePrice(
                        address(this),
                        _sizeDelta,
                        position
                    ));
        
        // collect funding fee and uncollect fee based on full position size
        {
            dCache.posFee = 
                position.long0 
                ?
                uint256(rgFs.fundFeeAccum0) + (block.timestamp - rgFs.time).mul(uint256(rgFs.fundFee0))
                :
                uint256(rgFs.fundFeeAccum1) + (block.timestamp - rgFs.time).mul(uint256(rgFs.fundFee1));

            // collect funding fee
            dCache.fee = position.size.mul(dCache.posFee - uint256(position.entryFdAccum)).div(1000000);
            position.entryFdAccum = uint64(dCache.posFee);
           
            dCache.fee += position.uncollectFee;
            position.uncollectFee = 0;

            dCache.posFee = FullMath.mulDiv(roxUtils.positionFeeBasisPoint(), position.size, RATIO_PREC);
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
                revert("infDecCol");
            }
        }


        dCache.payBack = 0;//zero back to account
        if (dCache.isLiq){
            dCache.del = true;
            position.collateral = 0;
            _sizeDelta = position.size;
            _collateralDelta = 0;
            dCache.fee += dCache.posFee;
        }else{
            if (_sizeDelta < position.size){
                dCache.profitDelta = FullMath.mulDiv(_sizeDelta, dCache.profitDelta, position.size);
                dCache.posFee = FullMath.mulDiv(_sizeDelta, position.size, position.size);
            }

            dCache.fee += dCache.posFee;

            //collateral > fullDec + _collateralDelta as checked before.
            if (dCache.hasProfit){
                dCache.payBack += dCache.profitDelta;
                // force settle
                if (_feeRecipient != position.account){
                    dCache.payBackSettle = dCache.payBack.div(10);
                    dCache.payBack -= dCache.payBackSettle ;
                }
            }else{
                position.collateral -= dCache.profitDelta;
            }

            // settle fee
            position.collateral -= dCache.fee;
            if (dCache.del){
                // pay remaining collateral back to trader
                _collateralDelta = position.collateral;
            }

            if (_collateralDelta > 0){
                position.collateral -= _collateralDelta;
                dCache.payBack += _collateralDelta;
            }
        }

        // valid max leverage
        if (position.collateral > 0){
            position.size = position.size.sub(_sizeDelta);
            require(position.collateral.mul(MAX_LEVERAGE) < position.size, "maxL");
            require(position.size > 0, "empSize");
        }else{
            dCache.del = true;
            _sizeDelta = position.size;
        }

        //global update
        {
            uint32 t = uint32(block.timestamp.div(60));
            if (position.long0) {
                globalLong0 = globalLong0.sub(_sizeDelta);
                closeMinuteMap0[t] = closeMinuteMap0[t].add(_sizeDelta);
            } else {
                globalLong1 = globalLong1.sub(_sizeDelta);
                closeMinuteMap1[t] = closeMinuteMap1[t].add(_sizeDelta);
            }
        }

        // settle fee
        {
            // trans. to sameside token
            dCache.feeDist = position.long0 ? 
                TradeMath.token1to0NoSpl(dCache.fee, dCache.closePrice)
                : 
                TradeMath.token0to1NoSpl(dCache.fee, dCache.closePrice);
                
            if (dCache.feeDist > position.transferIn){
                dCache.feeDist = position.transferIn;
            }
            position.transferIn -= dCache.feeDist;
        }

        // Settle part Profit, Loss & Fees settlement
        {
            if (dCache.isLiq){
                // pay fee to liq. executor if position is liquidated
                position.long0 ? _transferOut0(position.liqResv, _feeRecipient) : _transferOut1(position.liqResv, _feeRecipient);
            }else{
                // pay fee back to trader if not liquidated
                position.transferIn += position.liqResv;
                position.liqResv = 0; // can be ignored
            }

            uint256 withdrawFromPool = 0;

            if (dCache.payBack > 0) {
                dCache.payBack = position.long0
                    ? TradeMath.token1to0NoSpl(dCache.payBack, dCache.closePrice)
                    : TradeMath.token0to1NoSpl(dCache.payBack, dCache.closePrice);


                if (dCache.payBackSettle > 0){
                    dCache.payBackSettle = position.long0
                        ? TradeMath.token1to0NoSpl(dCache.payBackSettle, dCache.closePrice)
                        : TradeMath.token0to1NoSpl(dCache.payBackSettle, dCache.closePrice);
                    dCache.payBackSettle = position.transferIn > dCache.payBackSettle ?
                            dCache.payBackSettle
                            :
                            position.transferIn;

                    position.transferIn = position.transferIn.sub(dCache.payBackSettle);
                    position.long0 ? _transferOut0(dCache.payBackSettle, _feeRecipient) : _transferOut1(dCache.payBackSettle, _feeRecipient);
                    dCache.payBackSettle = 0;
                }


                if (dCache.payBack <= position.transferIn){
                    position.transferIn = position.transferIn.sub(dCache.payBack);
                    position.long0 ? _transferOut0(dCache.payBack, position.account) : _transferOut1(dCache.payBack, position.account);
                    dCache.payBack = 0;
                }
                else {
                    if (position.transferIn > 0){
                        dCache.payBack = dCache.payBack.sub(position.transferIn);
                        position.long0 ? _transferOut0(position.transferIn, position.account) : _transferOut1(position.transferIn, position.account);
                        position.transferIn = 0;
                    }
                    withdrawFromPool = dCache.payBack;
                }
            }

            bool _withdraw = withdrawFromPool > 0;
            if (dCache.del && !_withdraw){
                // pay remain token to spotPool
                withdrawFromPool += position.transferIn;
            }
            settle(position.account, position.long0, _withdraw, withdrawFromPool, dCache.feeDist);
        }


        // Run after function settle() as reserved amount loaded in function settle()
        {
            uint256 _resvDelta = position.reserve.mul(_sizeDelta).div(position.size);
            position.reserve = position.reserve.sub(_resvDelta);
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
            // emit DecreasePosition(key, address(this), spotPool, _sizeDelta, position);
        }
        return (dCache.del, dCache.isLiq, rtnDelta, _acc);
    }




    //---------------------------------------- PRIVATE Functions --------------------------------------------------
    function _increaseReserve(uint256 _delta, bool _token0) private {
        uint256 perpThres = IRoguexFactory(factory).perpThres();
        if (_token0) {
            reserve0 = reserve0.add(_delta);
            (uint256 r0, ) = IRoxSpotPool(spotPool).availableReserve(true, false);
            require(r0 >= reserve0 * perpThres / 1000, "t0p");
        } else {
            reserve1 = reserve1.add(_delta);
            (, uint256 r1) = IRoxSpotPool(spotPool).availableReserve(true, false);
            require(r1 >= reserve1 * perpThres / 1000, "t1p");
        }
    }

    function _decreaseReserve(uint256 _delta, bool _token0) private {
        if (_token0) {
            reserve0 = reserve0.sub(_delta, "-0");
        } else {
            reserve1 = reserve1.sub(_delta, "-1");
        }
    }

    // function _validateDecrease(
    //     uint256 _size,
    //     uint256 _sizeDelta,
    //     uint256 _collateral,
    //     uint256 _collateralDelta
    // ) private pure {
    //     require(_size > 0, "vd1");
    //     require(_size >= _sizeDelta, "vd2");
    //     require(_collateral >= _collateralDelta, "vd3");
    //     // if (_sizeDelta > 0 && _sizeDelta < _size)
    //         // require(_collateral.sub(_collateralDelta).mul(MAX_LEVERAGE) > _size.sub(_sizeDelta), "maxLev");
    // }

    function _validatePosition(
        uint256 _size,
        uint256 _collateral
    ) private pure {
        if (_size == 0) {
            require(_collateral == 0, "r3");
            return;
        }
        require(_size > _collateral, "r4");
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
            return sBalance0.sub(prevBalance, "sb0");
        }else{
            uint256 prevBalance = sBalance1;
            sBalance1 = balance1();
            return sBalance1.sub(prevBalance, "sb1");
        }
    }

    function _transferOut0(uint256 _amount0, address _recipient) private {
        if (_amount0 > 0){
            TransferHelper.safeTransfer(token0, _recipient, _amount0);
            sBalance0 = balance0();
        }
    }

    function _transferOut1(uint256 _amount1, address _recipient) private {
        if (_amount1 > 0){
            TransferHelper.safeTransfer(token1, _recipient, _amount1);
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



    function settle(
        address _recipient,
        bool _is0,
        bool _burn,
        uint256 _tokenAmount,
        uint256 _feeAmount
    ) internal {
        TradeData.SettleCache memory bCache;
        //todo opt: pass in as parameter to avoid sLoad
        ( , bCache.tickCur , , , , , ) = IRoxSpotPool(spotPool).slot0();
        bCache.startTickRoundLeft = TradeMath.tickPoint(bCache.tickCur) + (_is0 ? 600 : 0);


        uint256[] memory liqL;
        (liqL, bCache.liqSum, bCache.ltLiq, bCache.tkSum) = roxUtils.getLiqs(
                    spotPool,
                    bCache.startTickRoundLeft,
                    _is0 ? reserve0 : reserve1,
                    _is0
                );
        if(!_is0){
            liqL = TradeMath.reverse(liqL);
            bCache.startTickRoundLeft = bCache.startTickRoundLeft - int24(liqL.length * 600);
            // (bCache.startPr, bCache.startPs) = TradeMath.tickTo(bCache.startTickRoundLeft - int24(liqL.length * 600));
            // TradeMath.printInt("Resv startTickRoundLeft  ", bCache.startTickRoundLeft);
        }

        (bCache.startPr, bCache.startPs) = TradeMath.tickTo(bCache.startTickRoundLeft);
        bCache.endPs = uint16((uint256(bCache.startPr) + liqL.length - 1) / 12 );
        // TradeMath.printInt("Orig startTickRoundLeft  ", bCache.startTickRoundLeft);
        // console.log("  -----> PrRange : ", liqL.length);
        // console.log("startPr  ", bCache.startPr);
        // console.log("startPs  ", bCache.startPs, "--ToPs-->", bCache.endPs);
        
        bCache.curTime = block.timestamp;//uint256(block.timestamp).mul(PS_SPACING);
        bCache.bOdd = bCache.startPr % 2 > 0;


        for(uint i = 0; i < liqL.length; i++){
            (bCache.prId, bCache.psId) = TradeMath.tickTo(bCache.startTickRoundLeft + bCache.tmpSht);
            uint256 liq = _is0 ?
                uint128(FullMath.mulDiv(FullMath.mulDiv(liqL[0], i == liqL.length -1 ? bCache.ltLiq : liqL[i], bCache.liqSum), _tokenAmount, bCache.tkSum))
                :
                uint128(FullMath.mulDiv(FullMath.mulDiv(liqL[liqL.length -1], i == 0 ? bCache.ltLiq : liqL[i], bCache.liqSum), _tokenAmount, bCache.tkSum));
            
            if (_burn)
                require(liq <= liqL[i], "nsq");


            if (bCache.curPriceSlot < 1){ 
                bCache.curPriceSlot = pSlots.loadPs(bCache.psId);
                bCache.curPrTimeSlot = prUpdTime[bCache.psId];
                bCache.prCacheTime = PriceRange.prTime(bCache.curPrTimeSlot, bCache.prId);
            }
            else if (!bCache.bOdd){
                bCache.prCacheTime = PriceRange.prTime(bCache.curPrTimeSlot, bCache.prId);
            }
        
            // >>>>> 【Verification】. delete in release version.
            // feeSum += feedelta;
            // console.log("i      :", i);
            // TradeMath.printInt("_tmpSht:", _tmpSht);
            // TradeMath.printInt("_distLiq:", _distLiq);
            // TradeMath.printInt("liq:", liq);
            // console.log("liqL[i]:", liqL[i]);
            // tokenCnt += uint256(SqrtPriceMath.getAmount0Delta(
            //     TickMath.getSqrtRatioAtTick(bCache.startTickRoundLeft + int24(i * 600)),
            //     TickMath.getSqrtRatioAtTick(bCache.startTickRoundLeft + int24(i * 600 + 600)),
            //     liq
            // ));

            //TODO:  combine update perpPositions with same liquidity to save gas
            IRoxSpotPool(spotPool).updatePnl(
                bCache.startTickRoundLeft + bCache.tmpSht, 
                bCache.startTickRoundLeft + (bCache.tmpSht+= 600), 
                bCache.tickCur,
                _burn ? -int128(liq) : int128(liq));

            // console.log(">>>>> Fee: ", _feeAmount, feeSum);
            // Update P.R in current P.S
            // uint32 priceL = bCache.psTime > 0 ? TradeMath.priceInPs(priceSlot[bCache.psTime + bCache.psId], bCache.psId) : 1e4;
            uint32 priceL = TradeMath.priceInPs(bCache.curPriceSlot, bCache.prId);
            // TradeMath.printInt("TickLeft ", bCache.startTickRoundLeft );
            // console.log(">>> Price:", uint256(priceL));
            priceL = TradeMath.updatePrice(int128(liqL[i]), _burn ? -int128(liq) : int128(liq), priceL);
            // console.log("       to  ------> ", uint256(priceL));
            bCache.curPriceSlot = TradeMath.updatePs(bCache.curPriceSlot, bCache.prId, priceL);
        
            // Fee Distribution is different from liq. dist.
            // TODO: already calculated in previous update price
            //       combine function variables to save gas.
            prs.updatePerpFee(
                bCache.prCacheTime,
                bCache.curTime,
                bCache.prId,
                priceL,
                _burn ? liqL[i] - liq  : liqL[i] + liq,
                FullMath.mulDiv(_feeAmount, i == liqL.length -1 ? bCache.ltLiq : liqL[i], bCache.liqSum),
                _is0);

            // force update @start&end
            bool updT = false;
            if (i == 0 && bCache.bOdd){
                prs[PriceRange.prTimeId(bCache.prId-1, bCache.curTime)]
                    = prs[PriceRange.prTimeId(bCache.prId-1, bCache.prCacheTime)];
                updT = true;
            }
            else if (i == liqL.length -1 && !bCache.bOdd){
                prs[PriceRange.prTimeId(bCache.prId+1, bCache.curTime)]
                    = prs[PriceRange.prTimeId(bCache.prId+1, bCache.prCacheTime)];
                updT = true;
            }

            //update pr time if odd or last
            if (updT || bCache.bOdd){
                bCache.curPrTimeSlot = PriceRange.updatePrTime(bCache.curPrTimeSlot, bCache.prId, bCache.curTime);
            }

            //update current price slot if next cross or latest loop
            if (TradeMath.isRightCross(bCache.prId) || i == liqL.length -1){ 
                // console.log(">>> Update [pr]:", bCache.prId, "  >>> [ps]:", bCache.psId);
                // priceSlot[TradeMath.toPsEnc(bCache.psTime, bCache.psId)] = bCache.curPriceSlot;
                pSlots.writePs(bCache.psId, bCache.curPriceSlot);//sWrite to update
                prUpdTime[bCache.psId] = bCache.curPrTimeSlot;
                bCache.curPriceSlot = 0;//renew pSlot
                // bCache.curPriceSlot = 0; //do not need reset
            } 
            bCache.bOdd = !bCache.bOdd;
        }

        if (_burn){
            _is0 ? _transferOut0(_feeAmount, spotPool) : _transferOut1(_feeAmount, spotPool);
        }
        else{
            _is0 ? _transferOut0(_tokenAmount.add(_feeAmount), spotPool) : _transferOut1(_tokenAmount.add(_feeAmount), spotPool);
        }
        IRoxSpotPool(spotPool).perpSettle(_tokenAmount, _is0, _burn, _recipient);
        
        //TODO:
        //  > emit Events
    }

    function tPid(bool l0) public override view returns (uint256){
        return l0 ?
            posResv0.minPos()
            :
            posResv1.maxPos();
    }

    // function pKeys(bool l0) public override view returns (bytes32[] memory){
    //     return l0 ? 
    //             l0pos.valuesAt(0, l0pos.length())
    //             :
    //             l1pos.valuesAt(0, l1pos.length());
    // }

    function updateFundingRate(
        ) public returns (uint64, uint64) {
        uint256 curT = block.timestamp;
        uint256 tGap = curT - uint256(rgFs.time);
        if (tGap > 0){
            uint256 l0rec = IRoxSpotPool(spotPool).l0rec();
            uint256 l1rec = IRoxSpotPool(spotPool).l1rec();
            uint256 fdps = roxUtils.fdFeePerS();
            rgFs.fundFeeAccum0 += uint64(tGap.mul(uint256(rgFs.fundFee0)));
            rgFs.fundFeeAccum1 += uint64(tGap.mul(uint256(rgFs.fundFee1)));
            rgFs.fundFee0 = uint32(l0rec > 0 ? FullMath.mulDiv(reserve0, fdps, l0rec) : 0);
            rgFs.fundFee1 = uint32(l1rec > 0 ? FullMath.mulDiv(reserve1, fdps, l1rec) : 0);
            rgFs.time = uint32(curT);
        }
        return  (rgFs.fundFeeAccum0, rgFs.fundFeeAccum1);
    }
}
