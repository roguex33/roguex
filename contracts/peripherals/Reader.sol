// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "../interfaces/IRoxSpotPool.sol";
import "../interfaces/IRoxPerpPool.sol";
import "../interfaces/IRoxUtils.sol";
import "../interfaces/IPerpUtils.sol";
import "../libraries/TradeData.sol";
import "../libraries/TradeMath.sol";
import "../libraries/PosRange.sol";
import "../libraries/LowGasSafeMath.sol";
import "../libraries/FullMath.sol";
import "../libraries/TickMath.sol";
import "../libraries/LiquidityMath.sol";
import "../libraries/SqrtPriceMath.sol";
import "../libraries/PriceRange.sol";
import '../libraries/TickRange.sol';

interface IPerpRouter {
    function getPositionKeys(
        address _account
    ) external view returns (bytes32[] memory);

    function poolRev(bytes32 _key) external view returns (address);
}

library DispData {
    struct DispTradePosition {
        address account;
        uint160 sqrtPriceX96;
        uint64 entryFundingFee;
        uint256 size;
        uint256 collateral;
        uint256 reserve;
        uint256 colToken;
        address token0;
        address token1;
        uint256 closePread;
        uint256 closeSqrtPriceX96;
        uint256 liqSqrtPriceX96;
        uint256 uncollectPerpFee;
        uint256 fundingFee;

        uint256 delta;
        bool isLiq;
        bool hasProfit;
        bool long0;
        uint32 openSpread;
        int32 closeSpread;
        uint24 fee;
        address pool;
        address spotPool;
        uint256 uncollectFee;
        string message;
    }

    struct FeeData {
        uint256 open0SqrtPriceX96;
        uint256 open1SqrtPriceX96;
        uint256 close0SqrtPriceX96;
        uint256 close1SqrtPriceX96;
        uint256 executionFee;
        uint256 positionFee;
        uint256 premiumLong0perHour;
        uint256 premiumLong1perHour;
        uint256 reserve0;
        uint256 reserve1;
        address token0;
        address token1;
        address spotPool;
        uint256 fundingFee0;
        uint256 fundingFee1;
        uint256 liquidity0;
        uint256 liquidity1;
    }
}

contract Reader {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for uint128;

    uint256 public constant RATIO_PREC = 1e6;
    uint256 public constant MAX_LEVERAGE = 80;

    IRoxUtils public roxUtils;

    constructor(address _roguUtils) {
        roxUtils = IRoxUtils(_roguUtils);
    }

    function poolReserveRate(address _spotPool) public view returns (uint256 rate0, uint256 rate1){
        (uint256 r0, uint256 r1) = IRoxSpotPool(_spotPool).availableReserve(true, true);
        uint256 l0rec = IRoxSpotPool(_spotPool).balance0();
        uint256 l1rec = IRoxSpotPool(_spotPool).balance1();
        IRoxPerpPool perpPool = IRoxPerpPool(IRoxSpotPool(_spotPool).roxPerpPool());

        rate0 = r0 > 0 ? 
                perpPool.reserve0() * 1000000 / r0
                :
                l0rec > 0 ? 1000000 : 0;
        rate0 = rate0 > 1000000 ? 1000000 : rate0;

        rate1 = r1 > 0 ? 
                perpPool.reserve1() * 1000000 / r1
                :
                l1rec > 0 ? 1000000 : 0;
        rate1 = rate1 > 1000000 ? 1000000 : rate1;
    }



    struct DecreaseCache {
        int24 closeTick;
        int24 curTick;
        uint32 curTime;
        uint24 closeSpread;
        bool del;
        bool isLiq;
        bool hasProfit;
        uint160 closePrice;
        uint160 twapPrice;
        uint256 payBack;
        uint256 fee;
        uint256 feeDist;
        uint256 profitDelta;
        uint256 profitFac;
        uint256 posFee;
        uint256 origCollateral;
        uint256 colAfterfee;
        uint256 origSize;
        uint256 decLiqPrice;
        uint256 keepLevColDelta;
        uint256 fundingFee;
    }

    function estimateDecrease(
        address _perpPool,
        uint256 _sizeDelta,
        uint256 _collateralDelta,
        bytes32 _key
    )
        public
        view
        returns (
            DecreaseCache memory dCache,
            TradeData.TradePosition memory position,
            string memory
        )
    {
        position = IRoxPerpPool(_perpPool).getPositionByKey(_key);
        address _spotPool = IRoxPerpPool(_perpPool).spotPool();
        dCache.origCollateral = position.collateral;
        dCache.origSize = position.size;

        if (position.size < 1) return (dCache, position, "empty size");

        if (_sizeDelta + _collateralDelta < 1) _sizeDelta = position.size;

        if (position.size == _sizeDelta) {
            dCache.del = true;
            _collateralDelta = 0;
        } else if (_collateralDelta == position.collateral) {
            _sizeDelta = position.size;
            _collateralDelta = 0;
            dCache.del = true;
        } else if (_sizeDelta > position.size) {
            return (dCache, position, "exceed size");
        }

        (dCache.closePrice, dCache.twapPrice, dCache.closeSpread) = roxUtils.gClosePrice(
                        _perpPool,
                        _sizeDelta,
                        position,
                        false
                    );
                            
        dCache.closeSpread -= 1000000;
        
        position.openSpread -= 1000000;

        TradeData.RoguFeeSlot memory rgFs = IRoxPerpPool(_perpPool).rgFeeSlot();
        // collect funding fee and uncollect fee based on full position size
        {
            dCache.posFee = 
                position.long0 
                ?
                uint256(rgFs.fundFeeAccum0) + (block.timestamp - rgFs.time).mul(uint256(rgFs.fundFee0))
                :
                uint256(rgFs.fundFeeAccum1) + (block.timestamp - rgFs.time).mul(uint256(rgFs.fundFee1));

            // collect funding fee
            dCache.fee = dCache.posFee > uint256(position.entryFdAccum) ? 
                                FullMath.mulDiv(position.size, dCache.posFee - uint256(position.entryFdAccum), 1e10)
                                :
                                0;

            position.entryFdAccum = uint64(dCache.posFee);
           
            dCache.fee += position.uncollectFee;
            dCache.fundingFee = dCache.fee;
            // position.uncollectFee = 0; // do not clear here

            dCache.posFee = roxUtils.collectPosFee(position.size, IRoxPerpPool(_perpPool).spotPool());
        }
        // Calculate PNL
        // (dCache.hasProfit, dCache.profitDelta) = TradeMath.getDelta(
        //     position.long0,
        //     uint256(position.entrySqrtPriceX96),
        //     dCache.closePrice,
        //     position.size
        // );

        (dCache.hasProfit, dCache.profitDelta, dCache.profitFac) = roxUtils.getDelta(
            _spotPool,
            dCache.closePrice,
            position
        );  


        // Position validation
        {
            uint256 fullDec = dCache.fee +
                dCache.posFee +
                (dCache.hasProfit ? 0 : dCache.profitDelta);
            if (fullDec >= position.collateral) {
                _sizeDelta = position.size;
                dCache.isLiq = true;
            } else if (fullDec + _collateralDelta > position.collateral) {
                _collateralDelta = position.collateral;
                // revert("infDecCol");
            }
        }

        if (dCache.isLiq) {
            dCache.payBack = 0;
            return (dCache, position, "liquidate");
        }

        {
            if (_sizeDelta < position.size){
                dCache.profitDelta = FullMath.mulDiv(_sizeDelta, dCache.profitDelta, position.size);
                dCache.posFee = FullMath.mulDiv(_sizeDelta, dCache.posFee, position.size);
            }
            dCache.fee += dCache.posFee;


            //collateral > fullDec + _collateralDelta as checked before.
            if (dCache.hasProfit){
                dCache.payBack += dCache.profitDelta;
            }else{
                position.collateral = position.collateral.sub(dCache.profitDelta);// size checked before
            }

            // settle fee
            position.collateral = position.collateral.sub(dCache.fee);// size checked before
            dCache.colAfterfee = dCache.origCollateral.sub(dCache.fee);

            dCache.keepLevColDelta = FullMath.mulDiv(_sizeDelta, position.collateral, position.size);

            if (dCache.del){ 
                // pay remaining collateral back to trader
                _collateralDelta = position.collateral;
            }
            if (_collateralDelta > 0){
                if(position.collateral <_collateralDelta)
                    return (dCache, position, "exceed collateral");
                position.collateral = position.collateral.sub(_collateralDelta);
                dCache.payBack += _collateralDelta;
            }
        }

        // valid max leverage
        if (position.collateral > 0) {
            position.size = position.size.sub(_sizeDelta);
            if (position.collateral.mul(MAX_LEVERAGE) < position.size) {
                dCache.payBack = 0;
                return (dCache, position, "maxL");
            }

            (, , dCache.closeSpread) = roxUtils.gClosePrice(
                        _perpPool,
                        position.size,
                        position,
                        false
                    );
            dCache.closeSpread -= 1000000;

            dCache.decLiqPrice = estimateLiqPrice(
                        position.long0, 
                        position.collateral, 
                        position.entrySqrtPriceX96, 
                        uint256(dCache.closeSpread),
                        position.size
                );
        } else {
            dCache.del = true;
            _sizeDelta = position.size;
            position.size = 0;
        }

        // settle fee
        {
            // trans. to sameside token
            dCache.feeDist = position.long0
                ? TradeMath.token1to0NoSpl(dCache.fee, dCache.twapPrice)
                : TradeMath.token0to1NoSpl(dCache.fee, dCache.twapPrice);

            if (dCache.feeDist > position.transferIn) {
                dCache.feeDist = position.transferIn;
            }
            position.transferIn -= uint128(dCache.feeDist);
        }

        // Settle part Profit, Loss & Fees settlement
        {
            if (dCache.payBack > 0) {
                dCache.payBack = position.long0
                    ? TradeMath.token1to0NoSpl(
                        dCache.payBack,
                        dCache.twapPrice
                    )
                    : TradeMath.token0to1NoSpl(
                        dCache.payBack,
                        dCache.twapPrice
                    );
            }
        }

        return (dCache, position, "");
    }


    function estimateDecreaseL(
        address _perpPool,
        uint256 _sizeDelta,
        bytes32 _key
    )
        public
        view
        returns (
            DecreaseCache memory dCache,
            TradeData.TradePosition memory position,
            string memory
        )
    {
        position = IRoxPerpPool(_perpPool).getPositionByKey(_key);
        address _spotPool = IRoxPerpPool(_perpPool).spotPool();
        dCache.origCollateral = position.collateral;
        dCache.origSize = position.size;

        if (position.size < 1) return (dCache, position, "empty size");

        if (position.size == _sizeDelta) {
            dCache.del = true;
        }else if (_sizeDelta > position.size) {
            return (dCache, position, "exceed size");
        }

        (dCache.closePrice, dCache.twapPrice, dCache.closeSpread) = roxUtils.gClosePrice(
                        _perpPool,
                        _sizeDelta,
                        position,
                        false
                    );
                            
        dCache.closeSpread -= 1000000;
        
        position.openSpread -= 1000000;

        TradeData.RoguFeeSlot memory rgFs = IRoxPerpPool(_perpPool).rgFeeSlot();
        // collect funding fee and uncollect fee based on full position size
        {
            dCache.posFee = 
                position.long0 
                ?
                uint256(rgFs.fundFeeAccum0) + (block.timestamp - rgFs.time).mul(uint256(rgFs.fundFee0))
                :
                uint256(rgFs.fundFeeAccum1) + (block.timestamp - rgFs.time).mul(uint256(rgFs.fundFee1));

            // collect funding fee
            dCache.fee = dCache.posFee > uint256(position.entryFdAccum) ? 
                        FullMath.mulDiv(position.size, dCache.posFee - uint256(position.entryFdAccum), 1e10)
                        :
                        0;

            position.entryFdAccum = uint64(dCache.posFee);
           
            dCache.fee += position.uncollectFee;
            dCache.fundingFee = dCache.fee;
            // position.uncollectFee = 0;//do not clear here

            dCache.posFee = roxUtils.collectPosFee(position.size, IRoxPerpPool(_perpPool).spotPool());
        }
        // Calculate PNL

        (dCache.hasProfit, dCache.profitDelta, dCache.profitFac) = roxUtils.getDelta(
            _spotPool,
            dCache.closePrice,
            position
        );  

        // Position validation
        {
            uint256 fullDec = dCache.fee +
                dCache.posFee +
                (dCache.hasProfit ? 0 : dCache.profitDelta);
            if (fullDec >= position.collateral) {
                _sizeDelta = position.size;
                dCache.isLiq = true;
            } 
        }

        if (dCache.isLiq) {
            dCache.payBack = 0;
            return (dCache, position, "liquidate");
        }

        {
            if (_sizeDelta < position.size){
                dCache.profitDelta = FullMath.mulDiv(_sizeDelta, dCache.profitDelta, position.size);
                dCache.posFee = FullMath.mulDiv(_sizeDelta, dCache.posFee, position.size);
            }
            dCache.fee += dCache.posFee;


            //collateral > fullDec + _collateralDelta as checked before.
            if (dCache.hasProfit){
                dCache.payBack += dCache.profitDelta;
            }else{
                position.collateral = position.collateral.sub(dCache.profitDelta);// size checked before
            }

            // settle fee
            position.collateral = position.collateral.sub(dCache.fee);// size checked before
            dCache.colAfterfee = dCache.origCollateral.sub(dCache.fee);

            dCache.keepLevColDelta = FullMath.mulDiv(_sizeDelta, position.collateral, position.size);

            if (dCache.del){
                // pay remaining collateral back to trader
                dCache.keepLevColDelta = position.collateral;
            }
            if (dCache.keepLevColDelta > 0){
                position.collateral = position.collateral.sub(dCache.keepLevColDelta);
                dCache.payBack += dCache.keepLevColDelta;
            }
        }

        // valid max leverage
        if (position.collateral > 0) {
            position.size = position.size.sub(_sizeDelta);
            if (position.collateral.mul(MAX_LEVERAGE) < position.size) {
                dCache.payBack = 0;
                return (dCache, position, "maxL");
            }

            (, , dCache.closeSpread) = roxUtils.gClosePrice(
                        _perpPool,
                        position.size,
                        position,
                        false
                    );
            dCache.closeSpread -= 1000000;

            dCache.decLiqPrice = estimateLiqPrice(
                        position.long0, 
                        position.collateral, 
                        position.entrySqrtPriceX96, 
                        uint256(dCache.closeSpread),
                        position.size
                );
        } else {
            dCache.del = true;
            _sizeDelta = position.size;
            position.size = 0;
        }

        // settle fee
        {
            // trans. to sameside token
            dCache.feeDist = position.long0
                ? TradeMath.token1to0NoSpl(dCache.fee, dCache.twapPrice)
                : TradeMath.token0to1NoSpl(dCache.fee, dCache.twapPrice);

            if (dCache.feeDist > position.transferIn) {
                dCache.feeDist = position.transferIn;
            }
            position.transferIn -= uint128(dCache.feeDist);
        }

        // Settle part Profit, Loss & Fees settlement
        {
            if (dCache.payBack > 0) {
                dCache.payBack = position.long0
                    ? TradeMath.token1to0NoSpl(
                        dCache.payBack,
                        dCache.twapPrice
                    )
                    : TradeMath.token0to1NoSpl(
                        dCache.payBack,
                        dCache.twapPrice
                    );
            }
        }

        return (dCache, position, "");
    }



    function posDispInfo(
        address _perpPool,
        bytes32 _key
    ) public view returns (DispData.DispTradePosition memory posx) {
        (
            DecreaseCache memory dCache,
            TradeData.TradePosition memory position,
            string memory message
        ) = estimateDecrease(_perpPool, 0, 0, _key);

        // (uint160 curPrice, , , , , , ) = IRoxSpotPool(IRoxPerpPool(_perpPool).spotPool()).slot0();

        posx.message = message;
        posx.pool = _perpPool;
        posx.account = position.account;
        posx.sqrtPriceX96 = position.entrySqrtPriceX96;
        posx.entryFundingFee = position.entryFdAccum;
        posx.fundingFee = dCache.fundingFee;

        posx.size = dCache.origSize;
        posx.collateral = dCache.origCollateral;
        posx.long0 = position.long0;
        posx.openSpread = position.openSpread;
        posx.uncollectFee = position.uncollectFee;

        posx.token0 = IRoxPerpPool(_perpPool).token0();
        posx.token1 = IRoxPerpPool(_perpPool).token1();
        posx.spotPool = IRoxPerpPool(_perpPool).spotPool();
        posx.fee = IRoxSpotPool(posx.spotPool).fee();

        posx.closeSqrtPriceX96 = dCache.closePrice;
        posx.closeSpread = dCache.closeSpread;
        posx.isLiq = dCache.isLiq;

        posx.liqSqrtPriceX96 = estimateLiqPrice(
            posx.long0,
            dCache.colAfterfee,
            posx.sqrtPriceX96,
            uint256(
                posx.closeSpread >= 0 ? posx.closeSpread : -posx.closeSpread
            ),
            posx.size
        );

        posx.hasProfit = dCache.hasProfit;
        posx.delta = dCache.profitDelta;
        posx.uncollectPerpFee = dCache.fee;
    }

    struct IncreaseCache{
        uint160 openPrice;
        int24 openTick;
        // int24 curTick;
        uint32 curTime;
        uint16 posId;
        uint160 twapPrice;
        uint32 spread;
    }

    function estimateIncrease(
        address _perpPool,
        address _account,
        uint128 _tokenDelta,
        uint256 _sizeDelta,
        bool _long0
        ) external view returns (TradeData.TradePosition memory position, uint256 liqPrice, uint160 prevOpenPrice, uint256 prevLiqPrice) {
        bytes32 key = TradeMath.getPositionKey(_account, _perpPool, _long0);
        //> token0:p  token1:1/p
        position = IRoxPerpPool(_perpPool).getPositionByKey(key);
        IncreaseCache memory iCache;
        address spotPool = IRoxPerpPool(_perpPool).spotPool();
        // Long0:
        //  collateral & size: token1
        //  reserve & transferin : token0
        prevOpenPrice = position.entrySqrtPriceX96;

        if (position.size.add(_sizeDelta) <1)   
            return (position, 0, prevOpenPrice, 0);


        DispData.DispTradePosition memory posx = posDispInfo(_perpPool, key);

        prevLiqPrice = posx.liqSqrtPriceX96;

  
        // uint256 iCache.curPrice = roxUtils.getSqrtTwapX96(spotPool, 3);
        (iCache.openPrice, iCache.openTick, iCache.twapPrice, iCache.spread) 
            = roxUtils.gOpenPrice(
                _perpPool,
                _sizeDelta,
                _long0, 
                false);
                
        // Update Collateral
        {
            //transfer in collateral is same as long direction
            if (_tokenDelta > 0){
                position.transferIn = position.transferIn.addu128(_tokenDelta);
                // (, int256 a0, int256 a1, , ) = roxUtils.estimate(spotPool, _long0, int256(lR), IRoxSpotPool(spotPool).fee());

                if (_long0){
                    uint256 _colDelta = TradeMath.token0to1NoSpl(_tokenDelta, uint256(iCache.twapPrice));
                    position.collateral = position.collateral.add(_colDelta);
                    // require(a0 > 0 && uint256(a0) == lR && a1 < 0, "iL0");
                    // position.collateral = position.collateral.add(uint256(-a1));
                }
                else{
                    uint256 _colDelta = TradeMath.token1to0NoSpl(_tokenDelta, uint256(iCache.twapPrice));
                    position.collateral = position.collateral.add(_colDelta);
                    // require(a1 > 0 && uint256(a1) == lR && a0 < 0, "iL1");
                    // position.collateral = position.collateral.add(uint256(-a0));
                }
            }
        }

        //Update price & time & entry liquidity
        {
            iCache.curTime = uint32(block.timestamp);
            // init if need
            if (position.size == 0) {
                position.account = _account;
                position.long0 = _long0;
                position.entrySqrtPriceX96 = iCache.openPrice;
                // position.entryIn0 = IRoxSpotPool(spotPool).tInAccum0();
                // position.entryIn1 = IRoxSpotPool(spotPool).tInAccum1();
                position.openSpread = iCache.spread;
                position.entryPos = PosRange.tickToPos(iCache.openTick);

            }
            else if (position.size > 0 && _sizeDelta > 0){
  
                // Update funding fee rate after reserve amount changed.
                {
                    TradeData.RoguFeeSlot memory rgFs = IRoxPerpPool(_perpPool).rgFeeSlot();
                    // (uint64 acum0, uint64 acum1) = updateFundingRate();
                    uint64 curAcum = 
                                position.long0 ?
                                rgFs.fundFeeAccum0 + uint64(uint256(iCache.curTime - rgFs.time) * (uint256(rgFs.fundFee0)))
                                :
                                rgFs.fundFeeAccum1 + uint64(uint256(iCache.curTime - rgFs.time) * (uint256(rgFs.fundFee1)));
                    if (position.entryFdAccum > 0){
                        uint256 _ufee = FullMath.mulDiv(position.size, 
                                curAcum > position.entryFdAccum ? uint256(curAcum - position.entryFdAccum) : 0, 1e10);
                        require(position.collateral > _ufee, "uCol");
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

                iCache.posId = PosRange.tickToPos(
                                    TickMath.getTickAtSqrtRatio(position.entrySqrtPriceX96));

                
            }
        }
        position.size += _sizeDelta;
        roxUtils.validPosition(position.collateral, position.size, spotPool);


        ( , , uint24 closeSpread) = roxUtils.gClosePrice(
                    _perpPool,
                    position.size,
                    position,
                    false
                );

        closeSpread -= 1000000;
        position.openSpread -= 1000000;
        liqPrice = estimateLiqPrice(
                _long0, 
                position.collateral, 
                position.entrySqrtPriceX96, 
                uint256(closeSpread),
                position.size
        );
    }

    function spreadPrice(
        address _tradePool,
        bool _long0,
        uint256 _size
    ) public view returns (uint256 openPrice, uint256 closePrice) {
        (openPrice, , , ) = IRoxUtils(roxUtils).gOpenPrice(
            _tradePool,
            _size,
            _long0,
            false
        );
        closePrice = IRoxUtils(roxUtils).getClosePrice(
            _tradePool,
            _long0,
            _size,
            false
        );
    }

    function _openLiquidity(
        address _spotPool,
        address _tradePool
    ) private view returns (uint256, uint256) {
        (uint256 b0, uint256 b1) = IRoxSpotPool(_spotPool).availableReserve(
            true,
            true
        );
        b0 = b0 / 2;
        b1 = b1 / 2;
        uint256 r0 = IRoxPerpPool(_tradePool).reserve0();
        uint256 r1 = IRoxPerpPool(_tradePool).reserve1();
        return (b0 > r0 ? (b0 - r0) : 0, b1 > r1 ? (b1 - r1) : 0);
    }

    function fee(
        address _tradePool
    ) public view returns (DispData.FeeData memory _fee) {
        // DispData.FeeData memory _fee;
        _fee.spotPool = IRoxPerpPool(_tradePool).spotPool();
        (uint160 curPrice, , , , , , ) = IRoxSpotPool(_fee.spotPool).slot0();
        _fee.token0 = IRoxPerpPool(_tradePool).token0();
        _fee.token1 = IRoxPerpPool(_tradePool).token1();

        (_fee.liquidity0, _fee.liquidity1) = _openLiquidity(
            _fee.spotPool,
            _tradePool
        );

        _fee.liquidity0 = TradeMath.token0to1NoSpl(_fee.liquidity0, curPrice);
        _fee.liquidity1 = TradeMath.token1to0NoSpl(_fee.liquidity1, curPrice);

        _fee.reserve0 = IRoxPerpPool(_tradePool).reserve0();
        _fee.reserve1 = IRoxPerpPool(_tradePool).reserve1();

        TradeData.RoguFeeSlot memory rgFS = IRoxPerpPool(_tradePool).rgFeeSlot();
        _fee.fundingFee0 = uint64(uint256(rgFS.fundFee0).mul(3600) / (1e3));
        _fee.fundingFee1 = uint64(uint256(rgFS.fundFee1).mul(3600) / (1e3));

        _fee.positionFee = IRoxSpotPool(_fee.spotPool).fee();
        // uint256 premiumLong0perHour;
        // uint256 premiumLong1perHour;
    }

    function getPosition(
        address _perpPool,
        address _account,
        bool _long0
    ) public view returns (TradeData.TradePosition memory) {
        return
            IRoxPerpPool(_perpPool).getPositionByKey(
                TradeMath.getPositionKey(_account, _perpPool, _long0)
            );
    }

    function getPositions(
        address _account,
        address _tradeRouter
    ) public view returns (DispData.DispTradePosition[] memory) {
        bytes32[] memory keyList = IPerpRouter(_tradeRouter).getPositionKeys(
            _account
        );
        DispData.DispTradePosition[]
            memory posx = new DispData.DispTradePosition[](keyList.length);

        for (uint i = 0; i < keyList.length; i++) {
            address _pool = IPerpRouter(_tradeRouter).poolRev(keyList[i]);
            posx[i] = posDispInfo(_pool, keyList[i]);
        }
        return posx;
    }


    function estimateLiqPrice(
        bool long0,
        uint256 collateral,
        uint256 entryPriceSqrt,
        uint256 spreadEstimated,
        uint256 size
    ) public pure returns (uint256 liqPriceSqrtX96) {
        if (size < 1  || collateral < 1 || size < collateral)
            return 0;

        uint256 pRg = FullMath.mulDiv(collateral, 1000000, size);
        pRg = pRg > spreadEstimated ? pRg - spreadEstimated : 0;

        //Long0 :
        // delta = (P_0^close - P_0^open) / P_0^open
        //Long1 :
        // delta = (P_1^close - P_1^open) / P_1^open
        //       = ( 1/P_0^close) - 1/P_0^open) / (1 / P_0^open)
        //       = (P_0^open - P_0^close) / P_0^close
        
        // long0 : 
        //                      col = size * (openSqrt * openSqrt - liqSqrt * liqSqrt ) / (openSqrt * openSqrt) 
        //               col / size = 1 - (liqSqrt / openSqrt)^2
        //   (liqSqrt / openSqrt)^2 = (size - col) / size
        //                  liqSqrt = (openSqrt^2 * (size - col) / size)^0.5
        //                  liqSqrt = (1 - col / size)^0.5  * openSqrt
        
        // long1 : 
        //                      col = size * (liqSqrt*liqSqrt - openSqrt*openSqrt) / liqSqrt*liqSqrt
        //               col / size = 1 - (oS*oS) / (lS * lS)
        //      (lS * lS) / (oS*oS) = size / ( size - col )
        //                  liqSqrt = ( oS * oS * size / ( size - col ) )^0.5 

    

        if (long0) {
            if (pRg > 1000000)
                liqPriceSqrtX96 = 0;
            else{
                liqPriceSqrtX96 =  TradeMath.sqrt(
                    FullMath.mulDiv(
                        FullMath.mulDiv(entryPriceSqrt , entryPriceSqrt, 10000000000),
                        (size - collateral) * 10000000000,
                        size)
                );
            }
            // return (_entryPriceSqrt > slpPrice ? _entryPriceSqrt.sub(slpPrice) : 0, closePrice);
        } else {
                liqPriceSqrtX96 =  TradeMath.sqrt(
                    FullMath.mulDiv(
                        FullMath.mulDiv(entryPriceSqrt , entryPriceSqrt, 10000000000),
                        size * 10000000000,
                        (size - collateral) )
                );
        }
    }


    function estimateSwap(
        address spotPool,
        bool zeroForOne,
        int256 amountSpecified
    )
        public
        view
        returns (uint160 sqrtPrice, int256 amount0, int256 amount1, uint256 resv)
    {
        uint128 endLiq;
        int24 endTick;
        (sqrtPrice, amount0, amount1, endTick, endLiq) = roxUtils.estimate(
            spotPool,
            zeroForOne,
            amountSpecified,
            IRoxSpotPool(spotPool).fee()
        );
        resv = 1000000;
        if (zeroForOne){            
            uint256 l1rec = IRoxSpotPool(spotPool).balance1();
            if (amount1 < 0) {
                l1rec = l1rec.sub(uint256(-amount1));
            }
            
            int24 leftBound = PriceRange.leftBoundaryTickWithin(endTick);

            uint256 midTk = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(leftBound),
                    sqrtPrice,
                    endLiq,
                    false);

            l1rec =  l1rec > midTk ? l1rec-midTk : 0;

            if (l1rec > 0)
                resv = FullMath.mulDiv(IRoxPerpPool(IRoxSpotPool(spotPool).roxPerpPool()).reserve1(), 1000000, l1rec);
        }else{
            uint256 l0rec = IRoxSpotPool(spotPool).balance0();
            if (amount0 < 0) {
                l0rec = l0rec.sub(uint256(-amount0));
            }
            int24 rightBound = PriceRange.rightBoundaryTick(endTick);

            uint256 midTk = SqrtPriceMath.getAmount0Delta(
                    sqrtPrice,
                    TickMath.getSqrtRatioAtTick(rightBound),
                    endLiq,
                    false);

            l0rec =  l0rec > midTk ? l0rec-midTk : 0;

            if (l0rec > 0){
                resv = FullMath.mulDiv(IRoxPerpPool(IRoxSpotPool(spotPool).roxPerpPool()).reserve0(), 1000000, l0rec);   
            }
        }
        resv = resv > 1000000 ? 1000000 : resv;
    }



    function centLiq(address _spotPool) external view returns (uint256 r0, uint256 r1) {
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = IRoxSpotPool(_spotPool).slot0();
        uint128 liquidity = IRoxSpotPool(_spotPool).liquidity();

        int256 curAmount = SqrtPriceMath.getAmount0Delta(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(TickRange.rightBoundaryTick(tick)),
                int128(liquidity)
            );
        r0 = uint256(curAmount >= 0 ? curAmount : -curAmount);


        curAmount = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(TickRange.leftBoundaryTickWithin(tick)),
                sqrtPriceX96,
                int128(liquidity));

        r1 = uint256(curAmount >= 0 ? curAmount : -curAmount); 
    }

    function token0t1NoSpl(
        address _spotPool,
        uint256 _amount0
    ) public view returns (uint256) {
        (uint160 price, , , , , , ) = IRoxSpotPool(_spotPool).slot0();
        return TradeMath.token0to1NoSpl(_amount0, uint256(price));
    }

    function token1t0NoSpl(
        address _spotPool,
        uint256 _amount1
    ) public view returns (uint256) {
        (uint160 price, , , , , , ) = IRoxSpotPool(_spotPool).slot0();
        return TradeMath.token1to0NoSpl(_amount1, uint256(price));
    }
}
