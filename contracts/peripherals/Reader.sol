// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../interfaces/IERC20Minimal.sol";
import "../interfaces/IRoxPerpPoolDeployer.sol";
import "../interfaces/IRoxSpotPool.sol";
import "../interfaces/IRoxPerpPool.sol";
import "../interfaces/IRoxUtils.sol";

import "../libraries/TradeData.sol";
import "../libraries/TradeMath.sol";

import "../libraries/LowGasSafeMath.sol";
import "../libraries/SafeCast.sol";
import "../libraries/Tick.sol";
import "../libraries/TickBitmap.sol";
import "../libraries/Position.sol";
import "../libraries/Oracle.sol";

import "../libraries/FullMath.sol";
import "../libraries/FixedPoint128.sol";
import "../libraries/TickMath.sol";
import "../libraries/LiquidityMath.sol";
import "../libraries/SqrtPriceMath.sol";
import "../libraries/SwapMath.sol";
import "../libraries/PriceRange.sol";

import "hardhat/console.sol";

interface ITk {
    function decimals() external view returns (uint8);
}

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
        uint32 positionTime;
        uint64 entryFundingFee;
        uint256 size;
        uint256 collateral;
        uint256 reserve;
        uint256 colToken;
        int256 realisedPnl;
        address token0;
        address token1;
        uint256 closePread;
        uint256 closeSqrtPriceX96;
        uint256 liqSqrtPriceX96;
        uint256 uncollectPerpFee;
        uint256 delta;
        bool isLiq;
        bool hasProfit;
        bool long0;
        int32 openSpread;
        int32 closeSpread;
        uint24 fee;
        address pool;
        address spotPool;
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

//update 230917  tickLiquidityGross uint128 ----> int128  todo: check  overflow?
contract Reader {
    using SafeMath for uint256;
    using SafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeERC20 for IERC20;

    uint256 public constant RATIO_PREC = 1e6;
    uint256 public constant MAX_LEVERAGE = 80;

    IRoxUtils public roxUtils;

    constructor(address _roguUtils) {
        roxUtils = IRoxUtils(_roguUtils);
    }

    struct DecreaseCache {
        uint160 curPrice;
        int24 closeTick;
        int24 curTick;
        uint32 curTime;
        bool del;
        bool isLiq;
        bool hasProfit;
        uint160 closePrice;
        uint256 payBack;
        uint256 fee;
        uint256 feeDist;
        uint256 profitDelta;
        uint256 posFee;
        uint256 origCollateral;
        uint256 origSize;
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
        dCache.closePrice = uint160(
            roxUtils.gClosePrice(_perpPool, _sizeDelta, position)
        );
        TradeData.RoguFeeSlot memory rgFs = IRoxPerpPool(_perpPool).rgFeeSlot();
        // collect funding fee and uncollect fee based on full position size
        {
            dCache.posFee = position.long0
                ? uint256(rgFs.fundFeeAccum0) +
                    (block.timestamp - rgFs.time).mul(uint256(rgFs.fundFee0))
                : uint256(rgFs.fundFeeAccum1) +
                    (block.timestamp - rgFs.time).mul(uint256(rgFs.fundFee1));

            // collect funding fee
            dCache.fee = position
                .size
                .mul(dCache.posFee - uint256(position.entryFdAccum))
                .div(1000000);
            position.entryFdAccum = uint64(dCache.posFee);

            dCache.fee += position.uncollectFee;
            position.uncollectFee = 0;

            dCache.posFee = FullMath.mulDiv(
                roxUtils.positionFeeBasisPoint(),
                position.size,
                RATIO_PREC
            );
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
            if (_sizeDelta < position.size) {
                dCache.profitDelta = FullMath.mulDiv(
                    _sizeDelta,
                    dCache.profitDelta,
                    position.size
                );
                dCache.posFee = FullMath.mulDiv(
                    _sizeDelta,
                    position.size,
                    position.size
                );
            }

            dCache.fee += dCache.posFee;

            //collateral > fullDec + _collateralDelta as checked before.
            if (dCache.hasProfit) {
                dCache.payBack += dCache.profitDelta;
            } else {
                position.collateral -= dCache.profitDelta;
            }

            // settle fee
            position.collateral -= dCache.fee;
            if (dCache.del) {
                // pay remaining collateral back to trader
                _collateralDelta = position.collateral;
            }

            if (_collateralDelta > 0) {
                position.collateral -= _collateralDelta;
                dCache.payBack += _collateralDelta;
            }
        }

        // valid max leverage
        if (position.collateral > 0) {
            position.size = position.size.sub(_sizeDelta);
            if (position.collateral.mul(MAX_LEVERAGE) > position.size) {
                dCache.payBack = 0;
                return (dCache, position, "maxL");
            }
        } else {
            dCache.del = true;
            _sizeDelta = position.size;
            position.size = 0;
        }

        // settle fee
        {
            // trans. to sameside token
            dCache.feeDist = position.long0
                ? TradeMath.token1to0NoSpl(dCache.fee, dCache.closePrice)
                : TradeMath.token0to1NoSpl(dCache.fee, dCache.closePrice);

            if (dCache.feeDist > position.transferIn) {
                dCache.feeDist = position.transferIn;
            }
            position.transferIn -= dCache.feeDist;
        }

        // console.log(">p3:", dCache.payBack);
        // console.log("payBack : ", payBack.div(1e18));
        // console.log("withdrawFromPool : ", withdrawFromPool.div(1e18));
        // Settle part Profit, Loss & Fees settlement
        {
            // pay fee back to trader if not liquidated
            position.transferIn += position.liqResv;
            position.liqResv = 0; // can be ignored

            uint256 withdrawFromPool = 0;
            if (dCache.payBack > 0) {
                dCache.payBack = position.long0
                    ? TradeMath.token1to0NoSpl(
                        dCache.payBack,
                        dCache.closePrice
                    )
                    : TradeMath.token0to1NoSpl(
                        dCache.payBack,
                        dCache.closePrice
                    );
                // console.log(">p:", dCache.payBack);

                if (dCache.payBack <= position.transferIn) {
                    position.transferIn = position.transferIn.sub(
                        dCache.payBack
                    );
                    dCache.payBack = 0;
                } else {
                    if (position.transferIn > 0) {
                        dCache.payBack = dCache.payBack.sub(
                            position.transferIn
                        );
                        position.transferIn = 0;
                    }
                    withdrawFromPool = dCache.payBack;
                }
                // console.log(">>> wl", withdrawFromPool);
            }
        }
    }


    function posDispInfo(
        address _perpPool,
        bytes32 _key
    ) public view returns (DispData.DispTradePosition memory posx) {
        // console.log('1');
        (
            DecreaseCache memory dCache,
            TradeData.TradePosition memory position,
            string memory message
        ) = estimateDecrease(_perpPool, 0, 0, _key);

        posx.message = message;
        posx.pool = _perpPool;
        posx.account = position.account;
        posx.sqrtPriceX96 = position.entrySqrtPriceX96;
        posx.entryFundingFee = position.entryFdAccum;
        posx.size = dCache.origSize;
        posx.collateral = dCache.origCollateral;
        posx.long0 = position.long0;
        posx.openSpread = position.openSpread;

        posx.token0 = IRoxPerpPool(_perpPool).token0();
        posx.token1 = IRoxPerpPool(_perpPool).token1();
        posx.spotPool = IRoxPerpPool(_perpPool).spotPool();
        posx.fee = IRoxSpotPool(posx.spotPool).fee();

        posx.closeSqrtPriceX96 = dCache.closePrice;
        posx.closeSpread = TradeMath.spread(
            dCache.closePrice,
            position.entrySqrtPriceX96
        );
        posx.isLiq = dCache.isLiq;

        posx.liqSqrtPriceX96 = estimateLiqPrice(
            posx.long0,
            posx.collateral,
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

    struct IncreaseCache {
        uint160 openPrice;
        int24 openTick;
        int24 curTick;
        uint32 curTime;
        uint160 curPrice;
        uint16 posId;
    }

    function estimateIncrease(
        address _perpPool,
        address _account,
        uint256 _tokenDelta,
        uint256 _sizeDelta,
        bool _long0
        ) external view returns (TradeData.TradePosition memory position, uint256 liqPrice) {
        bytes32 key = TradeMath.getPositionKey(_account, _perpPool, _long0);
        //> token0:p  token1:1/p
        position = IRoxPerpPool(_perpPool).getPositionByKey(key);
        IncreaseCache memory iCache;
    
        // Long0:
        //  collateral & size: token1
        //  reserve & transferin : token0
        if (position.size.add(_sizeDelta) <1)   
            return (position, 0);
        // uint256 iCache.curPrice = roxUtils.getSqrtTwapX96(spotPool, 3);
        // uint160 openPrice = uint160(getOpenPrice(_long0, _sizeDelta));
        (iCache.openPrice, iCache.openTick, iCache.curPrice, iCache.curTick) 
            = roxUtils.gOpenPrice(_perpPool, _long0, _sizeDelta);

        // Update Collateral
        {
            //transfer in collateral is same as long direction
            if (_tokenDelta > 0){
                uint256 lR = _tokenDelta.mul(95).div(100);
                position.transferIn += lR;
                position.liqResv += _tokenDelta - lR;

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

                // if (_long0){
                //     l0activeMap.setActive(position.entryPos);

                //     // l0pos[position.entryPos].add(key);
                //     // l0pos.add(key);
                //     // if (!l0active.contains(position.entryPos))
                //         // l0active.add(position.entryPos);
                //     // l0posMap.iPosMap(position.entryPos, l0pos[position.entryPos].length());
                // }else{
                //     l1activeMap.setActive(position.entryPos);
                //     // l1pos[position.entryPos].add(key);
                //     // l1pos.add(key);
                //     // if (!l1active.contains(position.entryPos))
                //         // l1active.add(position.entryPos);
                //     // l1posMap.iPosMap(position.entryPos, l1pos[position.entryPos].length());
                // }
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

                iCache.posId = TradeMath.tickToPos(
                                    TickMath.getTickAtSqrtRatio(position.entrySqrtPriceX96));

                
            }
            position.openSpread = TradeMath.spread(position.entrySqrtPriceX96, iCache.curPrice);
        }
        position.size += _sizeDelta;



        liqPrice = estimateLiqPrice(
                _long0, position.collateral, position.entrySqrtPriceX96, 
                uint256(position.openSpread >= 0 ? position.openSpread : -position.openSpread), position.size);
        
      
      
        // console.log("collateral : ", position.collateral);
        // console.log("size       : ", position.size);
        // console.log("curPrice   : ", iCache.curPrice);
        // console.log("entryPrice : ", position.entrySqrtPriceX96);
        // console.log("  liqPrice : ", liqPrice);
        TradeMath.printInt("openSpread : ", position.openSpread);
    }

    function spreadPrice(
        address _tradePool,
        bool _long0,
        uint256 _size
    ) public view returns (uint256 openPrice, uint256 closePrice) {
        openPrice = IRoxUtils(roxUtils).getOpenPrice(
            _tradePool,
            _long0,
            _size
        );
        closePrice = IRoxUtils(roxUtils).getClosePrice(
            _tradePool,
            _long0,
            _size
        );
    }

    function _openLiquidity(
        address _spotPool,
        address _tradePool
    ) private view returns (uint256, uint256) {
        // TODO: add fee

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
        _fee.fundingFee0 = rgFS.fundFee0;
        _fee.fundingFee1 = rgFS.fundFee1;

        _fee.positionFee = roxUtils.positionFeeBasisPoint();
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

            // TradeData.TradePosition memory pos = IRoxPerpPool(_pool).getPositionByKey(keyList[i]);
            // if (pos.size < 1)
            //     continue;

            // posx[i].pool = _pool;
            // posx[i].account = pos.account;
            // posx[i].sqrtPriceX96 = pos.entrySqrtPriceX96;
            // posx[i].entryFundingFee = pos.entryFdAccum;
            // posx[i].size = pos.size;
            // posx[i].collateral = pos.collateral;
            // posx[i].size = pos.size;
            // posx[i].long0 = pos.long0;
            // posx[i].openSpread = pos.openSpread;

            // posx[i].token0 = IRoxPerpPool(_pool).token0();
            // posx[i].token1 = IRoxPerpPool(_pool).token1();
            // posx[i].spotPool = IRoxPerpPool(_pool).spotPool();
            // posx[i].fee = IRoxSpotPool(posx[i].spotPool).fee();

            // (posx[i].liqSqrtPriceX96, posx[i].closeSqrtPriceX96, posx[i].closePread) = getLiqPrice(
            //              pos.long0, pos.collateral, pos.entrySqrtPriceX96, pos.size);

            // (posx[i].hasProfit, posx[i].delta) = TradeMath.getDelta(pos.long0,
            //     uint256(pos.entrySqrtPriceX96), uint256(posx[i].closeSqrtPriceX96), pos.size);
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

        // require(collateral > 0, "0 collateral");
        require(size > 0, "0 size");
        uint256 pRg = FullMath.mulDiv(collateral, 1000000, size) + spreadEstimated;



        if (long0) {
            if (pRg > 1000000)
                liqPriceSqrtX96 = 0;
            else{
                liqPriceSqrtX96 = TradeMath.sqrt(
                    FullMath.mulDiv(
                        entryPriceSqrt,
                        entryPriceSqrt * (1000000 - pRg),
                        1000000
                    )
                );
            }

            // return (_entryPriceSqrt > slpPrice ? _entryPriceSqrt.sub(slpPrice) : 0, closePrice);
        } else {
            liqPriceSqrtX96 = TradeMath.sqrt(
                FullMath.mulDiv(
                    entryPriceSqrt,
                    entryPriceSqrt * (1000000 + pRg),
                    1000000
                )
            );
            // TradeMath.sqrt(_collateral.mul(100000000).div(_sizeDelta));
            // return (_entryPriceSqrt.add(slpPrice), closePrice);
        }
    }
}
