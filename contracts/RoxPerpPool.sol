// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "./interfaces/IRoguexFactory.sol";
import "./interfaces/IRoxPerpPoolDeployer.sol";
import "./interfaces/IRoxSpotPool.sol";
import "./interfaces/IRoxPosnPool.sol";
import "./interfaces/IRoxPerpPool.sol";
import "./interfaces/IERC20Minimal.sol";
import './interfaces/external/IWETH9.sol';
import "./interfaces/IRoxUtils.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/TradeData.sol";
import "./libraries/TradeMath.sol";
import "./libraries/FullMath.sol";
import "./libraries/TickMath.sol";
import "./libraries/SqrtPriceMath.sol";
import './libraries/PriceRange.sol';
import './libraries/PosRange.sol';
import "./libraries/LowGasSafeMath.sol";

contract RoxPerpPool is IRoxPerpPool {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for uint128;
    using PosRange for mapping(uint128 => uint256);


    event IncreasePosition(bytes32 key, address perpPool, address spotPool, uint256 sizeDelta, TradeData.TradePosition pos);
    event DecreasePosition(bytes32 key, address perpPool, address spotPool, uint256 sizeDelta, TradeData.TradePosition pos, bool isDel, uint160 closePrice);
    event CollectFee(uint256 fungdingFee, uint256 positionFee, uint256 feeDistribution, bool isToken0);
    event Liquidation(bytes32 key, bool hasProfit, uint256 profitDelta, uint256 fee, address receipt, uint128 liqReward);
    event Settle(bool burn, uint256 delta, uint256 fee);
    event TickPriceUpdate(uint16 pr, uint256 price);

    address public immutable factory;
    address public immutable weth;
    address public immutable posnPool;
    address public immutable override spotPool;
    address public immutable override token0;
    address public immutable override token1;
    IRoxUtils public immutable roxUtils;

    TradeData.RoguFeeSlot rgFs;

    uint256 public override sBalance0;
    uint256 public override sBalance1;
    uint256 public override reserve0;
    uint256 public override reserve1;

    mapping(uint32 => int256) public override closeMinuteMap0;
    mapping(uint32 => int256) public override closeMinuteMap1;

    // Perp Position Storage, perpKey => position
    mapping(bytes32 => TradeData.TradePosition) perpPositions;

    // method split position into ranges
    mapping(uint128 => uint256) public posResv0;
    mapping(uint128 => uint256) public posResv1;

    constructor() {
        address _factory;
        uint24 fee;
        (
            _factory,
            token0,
            token1,
            fee,
            spotPool,
            posnPool
        ) = IRoxPerpPoolDeployer(msg.sender).parameters();
        rgFs = TradeData.RoguFeeSlot(
                    uint32(block.timestamp),
                    1,1,0,0, fee);
        factory = _factory;
        weth = IRoguexFactory(_factory).weth();
        roxUtils = IRoxUtils(IRoguexFactory(_factory).utils());
    }


    function rgFeeSlot(
    ) external override view returns (TradeData.RoguFeeSlot memory){
        return rgFs;
    }


    struct IncreaseCache{
        uint160 openPrice;
        int24 openTick;
        uint32 curTime;
        uint16 posId;
        uint24 spread;
        uint160 twapPrice;

    }


    function increasePosition(
        address _account,
        uint256 _sizeDelta,
        bool _long0
        ) external override returns (bytes32, uint256, uint256) {
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
        (iCache.openPrice, iCache.openTick, iCache.twapPrice , iCache.spread) 
            = roxUtils.gOpenPrice(
                address(this),
                _sizeDelta,
                _long0, 
                false);

        // Update Collateral
        {
            //transfer in collateral is same as long direction
            uint128 tokenDelta = _transferIn(_long0);

            if (tokenDelta > 0){
                // uint128 lR = tokenDelta.mulu128(95) / (100);
                position.transferIn = position.transferIn.addu128(tokenDelta);
                // position.liqResv = position.liqResv.addu128(tokenDelta - lR);
                // (, int256 a0, int256 a1, , ) = roxUtils.estimate(spotPool, _long0, int256(lR), _rgfs.spotFee);

                if (_long0){
                    uint256 _colDelta = TradeMath.token0to1NoSpl(tokenDelta, uint256(iCache.twapPrice));
                    position.collateral = position.collateral.add(_colDelta);
                    // require(a0 > 0 && uint256(a0) == lR && a1 < 0, "iL0");
                    // position.collateral = position.collateral.add(uint256(-a1));
                }
                else{
                    uint256 _colDelta = TradeMath.token1to0NoSpl(tokenDelta, uint256(iCache.twapPrice));
                    position.collateral = position.collateral.add(_colDelta);
                    // require(a1 > 0 && uint256(a1) == lR && a0 < 0, "iL1");
                    // position.collateral = position.collateral.add(uint256(-a0));
                }
            }
        }
        //Update price & time & entry liquidity
        {
            // init if need
            if (position.size == 0) {
                position.account = _account;
                position.long0 = _long0;    
                position.entrySqrtPriceX96 = iCache.openPrice;
                position.entryIn0 = IRoxSpotPool(spotPool).tInAccum0();
                position.entryIn1 = IRoxSpotPool(spotPool).tInAccum1();
                position.entryPos = PosRange.tickToPos(iCache.openTick);
                position.openSpread = iCache.spread;
                position.openTime = uint32(iCache.curTime);
                // _long0 ? l0pos.add(key) : l1pos.add(key);
            }
            else if (position.size > 0 && _sizeDelta > 0){
                
                // Update funding fee rate after reserve amount changed.
                {
                    TradeData.RoguFeeSlot memory _rgfs = rgFs;
                    // (uint64 acum0, uint64 acum1) = updateFundingRate();
                    uint64 curAcum = 
                                position.long0 ?
                                _rgfs.fundFeeAccum0 + uint64(uint256(iCache.curTime - _rgfs.time) * (uint256(_rgfs.fundFee0)))
                                :
                                _rgfs.fundFeeAccum1 + uint64(uint256(iCache.curTime - _rgfs.time) * (uint256(_rgfs.fundFee1)));
                    if (position.entryFdAccum > 0){
                        uint256 _ufee = FullMath.mulDiv(position.size, uint256(curAcum - position.entryFdAccum), 1e9);
                        require(position.collateral > _ufee, "uf");
                        position.collateral -= _ufee;
                        position.uncollectFee = position.uncollectFee.addu128(uint128(_ufee));
                    }
                    position.entryFdAccum = curAcum; 
                }
                
                position.entrySqrtPriceX96 = uint160(TradeMath.nextPrice(
                                position.size,
                                position.entrySqrtPriceX96,
                                iCache.openPrice,
                                _sizeDelta
                            ) );

                position.entryIn0 = uint160(TradeMath.weightAve(
                                position.size,
                                position.entryIn0,
                                _sizeDelta,
                                IRoxSpotPool(spotPool).tInAccum0()
                            ) );

                position.entryIn1 = uint160(TradeMath.weightAve(
                                position.size,
                                position.entryIn1,
                                _sizeDelta,
                                IRoxSpotPool(spotPool).tInAccum1()
                            ) );

                position.openSpread = uint32(TradeMath.weightAve(
                                position.size,
                                position.openSpread,
                                _sizeDelta,
                                iCache.spread
                            ) );


                position.openTime = uint32(TradeMath.weightAve(
                                position.size,
                                uint256(position.openTime),
                                _sizeDelta,
                                iCache.curTime
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
        }


        //update global and position reserve
        if(_sizeDelta > 0){
            _decreaseReserve(position.reserve, _long0);
            position.reserve = uint128(_long0 ? 
                    TradeMath.token1to0NoSpl(position.size + _sizeDelta, position.entrySqrtPriceX96)
                    :
                    TradeMath.token0to1NoSpl(position.size + _sizeDelta, position.entrySqrtPriceX96));
            _increaseReserve(position.reserve, _long0);
            position.reserveMax = position.reserveMax > position.reserve ? position.reserveMax : position.reserve;
            if (position.long0){
                posResv0.posResvDelta(position.entryPos, position.reserve, true);
            }else{
                posResv1.posResvDelta(position.entryPos, position.reserve, true);
            }
            updateFundingRate(); //update funding rate after reserve changed.
            
            //update Size
            position.size = position.size + _sizeDelta;
        }

        roxUtils.validPosition(position.collateral, position.size, spotPool);
        emit IncreasePosition(key, address(this), spotPool, _sizeDelta, position);

        perpPositions[key] = position;
        return (key, _long0 ? TradeMath.token1to0NoSpl(_sizeDelta, uint256(iCache.openPrice)) : _sizeDelta, iCache.openPrice);
    }


    struct DecreaseCache{
        bool del;
        bool isLiq;
        bool hasProfit;
        uint160 closePrice;
        uint160 twapPrice;
        uint256 payBack;
        uint256 payBackSettle;
        uint256 fee;
        uint256 feeDist;
        uint256 profitDelta;
        uint256 posFee;
        uint128 resvDelta;
        uint128 rtnDelta;
    }

    function _validSender(address _owner) private view{
        require(msg.sender == _owner
                || IRoguexFactory(factory).approvedPerpRouters(msg.sender),"sd");
    }

    function decreasePosition(
        bytes32 _key,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        address _feeRecipient,
        bool _toETH
    ) external override returns (bool, bool, uint256, address, uint256) {
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
        

        (dCache.closePrice, dCache.twapPrice, ) = roxUtils.gClosePrice(
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
           
            dCache.fee += position.uncollectFee;
            position.uncollectFee = 0;

            dCache.posFee = roxUtils.collectPosFee(position.size, spotPool);
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

            uint128 liqReward = uint128(position.long0 ?
                            TradeMath.token1to0NoSpl(position.collateral/20, dCache.twapPrice)
                            : 
                            TradeMath.token0to1NoSpl(position.collateral/20, dCache.twapPrice));
            liqReward = liqReward > position.transferIn ?  position.transferIn : liqReward;
            position.long0 ? _transferOut0(liqReward, _feeRecipient, true) : _transferOut1(liqReward, _feeRecipient, true);
            position.transferIn = position.transferIn.subu128(liqReward);
        
            emit Liquidation(_key, dCache.hasProfit, dCache.profitDelta, dCache.fee, _feeRecipient, liqReward);
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
                    dCache.payBackSettle = dCache.payBack / 20;
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
                require(position.collateral >=_collateralDelta, "<c" );
                position.collateral = position.collateral - _collateralDelta;
                dCache.payBack += _collateralDelta;
            }
        }



        // valid max leverage
        if (position.collateral > 0){
            dCache.resvDelta = uint128(FullMath.mulDiv(position.reserve, _sizeDelta, position.size));
            position.size = position.size.sub(_sizeDelta);//check bef.
        }else{
            dCache.del = true;
            _sizeDelta = position.size;
            dCache.resvDelta = uint128(position.reserve);
        }

        if (!dCache.del)
            roxUtils.validPosition(position.collateral, position.size, spotPool);


        // settle fee
        {
            // trans. to sameside token
            dCache.feeDist = position.long0 ? 
                TradeMath.token1to0NoSpl(dCache.fee, dCache.twapPrice)
                : 
                TradeMath.token0to1NoSpl(dCache.fee, dCache.twapPrice);
            emit CollectFee(dCache.fee, dCache.fee - dCache.posFee, dCache.feeDist, position.long0);
            if (dCache.feeDist > position.transferIn){
                dCache.feeDist = position.transferIn;
            }
            position.transferIn = position.transferIn.subu128(uint128(dCache.feeDist));//distribute fees to spot pool
        }

        // settle part Profit, Loss & Fees settlement
        {
            uint256 withdrawFromPool = 0;
            if (dCache.payBack > 0) {
                dCache.payBack = position.long0
                    ? TradeMath.token1to0NoSpl(dCache.payBack, dCache.twapPrice)
                    : TradeMath.token0to1NoSpl(dCache.payBack, dCache.twapPrice);

                if (dCache.payBackSettle > 0){
                    dCache.payBackSettle = position.long0
                        ? TradeMath.token1to0NoSpl(dCache.payBackSettle, dCache.twapPrice)
                        : TradeMath.token0to1NoSpl(dCache.payBackSettle, dCache.twapPrice);
                    dCache.payBackSettle = position.transferIn > dCache.payBackSettle ?
                            dCache.payBackSettle
                            :
                            position.transferIn;

                    position.transferIn = position.transferIn.subu128(uint128(dCache.payBackSettle));
                    position.long0 ? _transferOut0(dCache.payBackSettle, _feeRecipient, true) : _transferOut1(dCache.payBackSettle, _feeRecipient, true);
                    dCache.payBackSettle = 0;
                }


                if (dCache.payBack <= position.transferIn){
                    position.transferIn = position.transferIn.subu128(uint128(dCache.payBack));
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
            position.reserve = position.reserve.subu128(dCache.resvDelta);
            _decreaseReserve(dCache.resvDelta, position.long0);        
        }

        // update funding fee rate
        updateFundingRate();

        address _acc = position.account;
        // Post-processing
        dCache.rtnDelta = uint128(position.long0 ? TradeMath.token1to0NoSpl(_sizeDelta, dCache.closePrice) : _sizeDelta);
        if (dCache.del){
            _delPosition(_key);
            // emit ClosePosition(key, position.account,
        }else{
            perpPositions[_key] = position;
        }
        emit DecreasePosition(_key, address(this), spotPool, _sizeDelta, position, dCache.del, dCache.closePrice);

        return (dCache.del, dCache.isLiq, dCache.rtnDelta, _acc, dCache.closePrice);
    }


    //---------------------------------------- PRIVATE Functions --------------------------------------------------
    function _increaseReserve(uint256 _delta, bool _token0) private {
        // uint32 t = uint32(block.timestamp / 60);
        uint256 perpThres = IRoxUtils(roxUtils).perpThres(spotPool);
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


    function _transferIn(bool _isToken0) private returns (uint128) {
        if (_isToken0){
            uint256 prevBalance = sBalance0;
            sBalance0 = balance0();
            require(sBalance0 > prevBalance, "b0");
            return uint128(sBalance0 - prevBalance);
            // return sBalance0.sub(prevBalance, "sb0");
        }else{
            uint256 prevBalance = sBalance1;
            sBalance1 = balance1();
            require(sBalance1 > prevBalance, "b0");
            return uint128(sBalance1 - prevBalance);  
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
        uint16 psId;
        uint16 prId;
        uint32 psTime;
        uint32 prCacheTime;
        uint32 curTime;
        //---slot----
        
        uint128 feeDt;
        uint128 feeCache;
        //---slot----

        uint128 liqDelta;
        uint128 endLiq;

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
        require(liqL.length > 0, "c");
        if (!_is0){
            bCache.startTickRound -= int24(liqL.length * 300);
        }

        (bCache.startPr, bCache.startPs) = PriceRange.tickTo(bCache.startTickRound);

        bCache.curTime = uint32(block.timestamp);//uint256(block.timestamp).mul(PS_SPACING);

        for(uint i = 0; i < liqL.length; i+=2){
            (bCache.prId, bCache.psId) = PriceRange.tickTo(bCache.startTickRound + bCache.tmpSht);
            if ( (_is0 && i+2 == liqL.length) || (!_is0 && i == 0)){
                bCache.liqDelta = uint128(FullMath.mulDiv(bCache.endLiq, _tokenAmount, bCache.resvCache));
                bCache.feeCache = uint128(FullMath.mulDiv(_feeAmount, bCache.endLiq, bCache.liqSum));
            }
            else{
                bCache.liqDelta = uint128(FullMath.mulDiv(liqL[i], _tokenAmount, bCache.resvCache));
                bCache.feeCache = uint128(FullMath.mulDiv(_feeAmount, liqL[i], bCache.liqSum));
            }

            if (bCache.curPriceSlot < 1){ 
                bCache.curPriceSlot = IRoxPosnPool(posnPool).priceSlot(bCache.psId);
                bCache.curPrTimeSlot = IRoxPosnPool(posnPool).timeSlot(bCache.psId);
                bCache.prCacheTime = PriceRange.prTime(bCache.curPrTimeSlot, bCache.prId);
            }

            //TODO:  combine update perpPositions with same liquidity to save gas

            // Update P.R in current P.S
            // uint32 priceL = bCache.psTime > 0 ? TradeMath.priceInPs(priceSlot[bCache.psTime + bCache.psId], bCache.psId) : 1e4;
            uint256 priceL = PriceRange.priceInPs(bCache.curPriceSlot, bCache.prId);

            // stop pnl update when price is too high or too low .
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
                bCache.liqDelta = 0;
            }else{
                IRoxSpotPool(spotPool).updatePnl(
                    bCache.startTickRound + bCache.tmpSht, 
                    bCache.startTickRound + (bCache.tmpSht+= 600), 
                    bCache.tickCur,
                    _burn ? -int128(bCache.liqDelta) : int128(bCache.liqDelta));

                priceL = PriceRange.updatePrice(liqL[i], bCache.liqDelta, priceL, _burn);
                emit TickPriceUpdate(bCache.prId, priceL);
                bCache.curPriceSlot = PriceRange.updateU32Slot(bCache.curPriceSlot, bCache.prId, priceL);
            }

            // Fee Distribution is different from liq. dist.
            // TODO: already calculated in previous update price
            //       combine function variables to save gas.
            
            IRoxPosnPool(posnPool).updatePerpFee(
                bCache.prCacheTime,
                bCache.curTime,
                bCache.prId,
                priceL,
                _burn ? liqL[i] - bCache.liqDelta  : liqL[i] + bCache.liqDelta,
                bCache.feeCache,
                _is0);
        

            bCache.curPrTimeSlot = PriceRange.updateU32Slot(bCache.curPrTimeSlot, bCache.prId, bCache.curTime);

            //update current price slot if next cross or latest loop
            if (PriceRange.isRightCross(bCache.prId) || i >= liqL.length -2){ 
                IRoxPosnPool(posnPool).writePriceSlot(bCache.psId, bCache.curPriceSlot);//sWrite to update
                IRoxPosnPool(posnPool).writeTimeSlot(bCache.psId, bCache.curPrTimeSlot);
                bCache.curPriceSlot = 0;//renew pSlot
                // bCache.curPriceSlot = 0; //do not need reset
            } 
        }
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
            uint256 fdps = roxUtils.fdFeePerS(spotPool);

            rgFs.fundFeeAccum0 += uint64(tGap*(uint256(rgFs.fundFee0)));
            rgFs.fundFeeAccum1 += uint64(tGap*(uint256(rgFs.fundFee1)));

            rgFs.fundFee0 = uint32(l0rec > 0 ? FullMath.mulDiv(reserve0, fdps, l0rec) : 0);
            rgFs.fundFee1 = uint32(l1rec > 0 ? FullMath.mulDiv(reserve1, fdps, l1rec) : 0);
            rgFs.time = uint32(curT);
        }
        return  (rgFs.fundFeeAccum0, rgFs.fundFeeAccum1);
    }
}
