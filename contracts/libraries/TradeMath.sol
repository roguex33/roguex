// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "../libraries/TickMath.sol";
import "../libraries/BitMath.sol";
import "../libraries/SqrtPriceMath.sol";
import "./FullMath.sol";
import "hardhat/console.sol";

library TradeMath {
    using SafeMath for uint256;
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint256 public constant ltprec = 1e12;
    uint256 public constant PS_SPACING = 100000;
    uint256 public constant PR_SPACING = 600;
    uint256 public constant PRICE_SPACING = 100; //1.0001^100 > 1%   17745 ranges > 70x 256 bit map

    function toPsEnc(uint psTime, uint psId) internal pure returns (uint256) {
        return uint256(psTime).mul(PS_SPACING).add(psId);
    }

    function weightAve(
        uint256 _weight0,
        uint256 _value0,
        uint256 _weight1,
        uint256 _value1
    ) internal pure returns (uint256) {
        return
            (
                FullMath.mulDiv(_weight0, _value0, ltprec).add(
                    FullMath.mulDiv(_weight1, _value1, ltprec)
                )
            ).mul(ltprec).div((_weight0.add(_weight1)));
    }

    function decreaseSpread(
        uint256 _fBase,
        uint256 _gap,
        uint256 _fDelta
    ) internal pure returns (uint256) {
        uint256 _bRatio = FullMath.mulDiv(_gap, ltprec, _fDelta);
        uint256 _exp = _gap.div(_fBase);
        _exp = _exp < 5 ? _exp : 5;
        for (uint i = 0; i < _exp; i++) {
            _bRatio = FullMath.mulDiv(_bRatio, _bRatio, ltprec);
        }
        return _bRatio;
    }

    function getPriceX96FromSqrtPriceX96(
        uint160 sqrtPriceX96
    ) internal pure returns (uint256 priceX96) {
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
    }

    function tkPosition(
        int24 tick
    ) internal pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(tick % 256);
    }

    function tickPoint(int24 tick) internal pure returns (int24) {
        return (tick / 600) * 600 - (tick < 0 ? 600 : 0);
    }

    // uint21 per Price, MaxValueofU21:1048575 => 104.0000 times max.
    // tick to price Range, priceRange is 0 ~ 2958, every 600Tick Per Range,
    function tickToPr(int24 tick) internal pure returns (uint16) {
        tick = (tick + 887272) / 600;
        // require(tick >= 0);
        return uint16(tick);
    }

    function prToTick(uint16 pr) internal pure returns (int24) {
        return (int24(pr) - 1478) * 600;
    }

    function prStartTick(uint256 pr) internal pure returns (int24) {
        require(pr < 3000, "nPR"); //2958 max range.
        int256 _tk = int256(pr * 600);
        return int24(_tk - 887272);
    }

    function prToPs(uint256 pr) internal pure returns (uint256) {
        return pr / 12;
    }

    function liqTrans(
        uint128 entryLiq,
        uint32 entryPrice,
        uint32 curPrice
    ) internal pure returns (uint128) {
        require(entryPrice > 0, "p=0");
        return
            uint128(
                FullMath.mulDiv(
                    uint256(entryLiq),
                    uint256(curPrice),
                    uint256(entryPrice)
                )
            );
    }

    function liqPrice(
        bool long0,
        uint256 collateral,
        uint256 entryPriceSqrt,
        uint256 spreadEstimated,
        uint256 size
    ) internal pure returns (uint256 liqPriceSqrtX96) {

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

    // zeroForOne: true for token0 to token1, false for token1 to token0
    function rightBoundaryTick(
        int24 tick) internal pure returns (int24){ 
        return prToTick(tickToPr(tick) + 1);
    }

    function leftBoundaryTick(
        int24 tick) internal pure returns (int24){
        return prToTick(tickToPr(tick-1));
    }

    function getDelta(
        bool _long0,
        uint256 _openPriceSqrtX96,
        uint256 _closePriceSqrtX96,
        uint256 _size
    ) internal pure returns (bool hasProfit, uint256 sizeDelta) {
        require(_openPriceSqrtX96 > 0, "e3");

        uint256 _openPriceX96 = FullMath.mulDiv(
            _openPriceSqrtX96,
            _openPriceSqrtX96,
            Q96
        );
        uint256 _closePriceX96 = FullMath.mulDiv(
            _closePriceSqrtX96,
            _closePriceSqrtX96,
            Q96
        );

        uint256 priceDelta = _openPriceX96 > _closePriceX96
            ? _openPriceX96.sub(_closePriceX96)
            : _closePriceX96.sub(_openPriceX96);

        //Long0 :
        // delta = (P_0^close - P_0^open) / P_0^open
        //Long1 :
        // delta = (P_1^close - P_1^open) / P_1^open
        //       = ( 1/P_0^close) - 1/P_0^open) / (1 / P_0^open)
        //       = (P_0^open - P_0^close) / P_0^close
        if (_long0) {
            uint256 delta = FullMath.mulDiv(_size, priceDelta, _openPriceX96);
            hasProfit = _closePriceX96 > _openPriceX96;
            // priceDelta = FullMath.mulDiv(1000000, priceDelta, _openPriceX96);
            return (hasProfit, delta);
        } else {
            hasProfit = _openPriceX96 > _closePriceX96;
            uint256 delta = FullMath.mulDiv(_size, priceDelta, _closePriceX96);
            // priceDelta = FullMath.mulDiv(1000000, priceDelta, _closePriceX96);
            return (hasProfit, delta);
        }
    }

    function sqrt(uint x) internal pure returns (uint y) {
        uint z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function liqToToken(
        bool _is0,
        uint256 _liq,
        uint256 _sqrtPrice
    ) internal pure returns (uint256) {
        if (_is0) {
            return _liq.div(_sqrtPrice);
        } else {
            return _liq.mul(_sqrtPrice);
        }
    }

    function nextPrice(
        uint256 _size,
        uint256 _entryPrice,
        uint256 _nextPrice,
        uint256 _sizeDelta
    ) internal pure returns (uint256) {
        //shift 8 to avoid overflow
        // uint256 _tps = ((_averagePrice.mul(_nextPrice)) >> 8).mul(
        //     _size.add(_sizeDelta)
        // );
        // uint256 _tpp = (
        //     _averagePrice.mul(_sizeDelta).add(_nextPrice.mul(_size))
        // ) >> 8;
        uint256 ampfP = (_entryPrice > _nextPrice ? _nextPrice : _entryPrice) /
            170141183460469231731687303715884105728 +
            1;

        _entryPrice = FullMath.mulDiv(_entryPrice, _entryPrice, ampfP * ampfP); //_entryPrice / ampfP * _entryPrice / ampfP;
        _nextPrice = FullMath.mulDiv(_nextPrice, _nextPrice, ampfP * ampfP); //_nextPrice / ampfP * _nextPrice / ampfP;

        //TODO:
        //   Change sqrt price calculation to normal price
        uint256 _sSum = _size.add(_sizeDelta);
        require(_sSum > 0, "eS");
        uint256 _tpp = FullMath.mulDiv(_entryPrice, _sizeDelta, _sSum) +
            FullMath.mulDiv(_nextPrice, _size, _sSum);

        uint256 nextP = FullMath.mulDiv(_entryPrice, _nextPrice, _tpp);
        nextP = sqrt(nextP) * ampfP;
        return nextP;
    }

    function nextPositionTime(
        uint256 _t0,
        uint256 _s0,
        uint256 _t1,
        uint256 _sDelta
    ) internal pure returns (uint256) {
        return
            (_t0.add(_t1)).mul(_s0).add(_sDelta.mul(_t1)).div(
                _s0.add(_s0).add(_sDelta)
            );
    }

    function getPositionKey(
        address _account,
        address _tradePool,
        bool _long0
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _tradePool, _long0));
    }

    function loadPs(
        uint256[247] storage self,
        uint256 psId
    ) internal view returns (uint256) {
        uint256 ps = self[psId];
        return
            ps > 0
                ? ps
                : 276069985512049908241159041501274605055310715980014228921659870958059600001;
    }

    function loadPrPrice(
        uint256[247] storage self,
        uint256 prId
    ) internal view returns (uint256) {
        uint256 ps = self[prId / 12];
        if (ps > 0) {
            return priceInPs(ps, prId);
        } else {
            return 10000;
        }
    }

    function writePs(
        uint256[247] storage self,
        uint256 psId,
        uint256 latestPs
    ) internal {
        self[psId] = latestPs > 0
            ? latestPs
            : 276069985512049908241159041501274605055310715980014228921659870958059600001;
    }

    //0 ---> 16, left to right
    function isRightCross(uint256 pr) internal pure returns (bool) {
        return pr % 12 == 11;
    }

    function isLeftCross(uint256 pr) internal pure returns (bool) {
        return pr % 12 == 0;
    }

    function prToPs(
        uint256[] memory pList
    ) internal pure returns (uint256 priceSlot) {
        require(pList.length == 12, "pL=12");
        // priceSlot = 0x1FFFFF & pList[11];
        for (uint i = 0; i < 12; i++) {
            // priceSlot = priceSlot << 21;
            priceSlot = priceSlot | ((0x1FFFFF & pList[i]) << (234 - i * 21));
        }
    }

    function tickTo(int24 tick) internal pure returns (uint16 pr, uint16 ps) {
        pr = uint16((tick + 887272) / 600);
        ps = pr / 12;
    }

    function isPsInit(uint256 psMap, uint ps) internal pure returns (bool) {
        return (psMap & (1 << (255 - ps))) > 0;
    }

    function reverse(
        uint[] memory _array
    ) internal pure returns (uint[] memory) {
        uint length = _array.length;
        uint[] memory reversedArray = new uint[](length);
        uint j = 0;
        for (uint i = length; i >= 1; i--) {
            reversedArray[j] = _array[i - 1];
            j++;
        }
        return reversedArray;
    }

    function updatePrice(
        int128 realLiq,
        int128 liqDelta,
        uint32 price
    ) internal pure returns (uint32) {
        if (price < 1) return 1e4;
        require(realLiq + liqDelta > 0, "price<0");
        return
            uint32(
                0x1FFFFF &
                    FullMath.mulDiv(
                        uint256(realLiq + liqDelta),
                        uint256(price),
                        uint256(realLiq)
                    )
            );
    }

    function updatePs(
        uint256 priceSlot,
        uint256 prId,
        uint256 price
    ) internal pure returns (uint256) {
        uint256 lc = (prId % 12) + 1;
        uint256 psm = 0x1FFFFF << (255 - 21 * (lc));
        priceSlot = priceSlot & (~psm);
        priceSlot = priceSlot | ((0x1FFFFF & price) << (255 - 21 * lc));
        return priceSlot;
    }

    function priceInPs(
        uint256 priceSlot,
        uint256 prId
    ) internal pure returns (uint32) {
        // require(ps < 247);
        // priceSlot = priceSlot >> (21 * (11 - (prId % 12)));
        // return uint32(0x1FFFFF & priceSlot);
        return 0x1FFFFF & uint32(priceSlot >> (234 - (21 * (prId % 12))));
    }

    //every 16 id(16bitPerId) stored in one uint256 slot
    function psToPrList(
        uint256 priceSlot
    ) internal pure returns (uint32[] memory priceList) {
        priceList = new uint32[](12);
        for (uint i = 0; i < 12; i++) {
            priceList[i] = 0x1FFFFF & uint32(priceSlot >> (234 - (21 * i)));
            // priceSlot = priceSlot >> 21;
        }
    }

    function combinePs(
        uint256 priceSlot1,
        uint256 priceSlot2,
        uint256 prId,
        bool keep1lft
    ) internal pure returns (uint256) {
        // require(ps2Id%12 > 0);
        uint256 mpMsk = (1 << (255 - 21 * (prId % 12) + 1)) - 1;
        if (keep1lft) return (priceSlot1 & (~mpMsk)) | (priceSlot2 & mpMsk);
        else return (priceSlot1 & mpMsk) | (priceSlot2 & (~mpMsk));
    }

    function encodePsRange(
        uint32[247] storage self,
        uint256 udpMap,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint256[] memory) {
        uint256 psStart = tickToPr(tickLower) / 12;
        uint256 psEnd = tickToPr(tickUpper) / 12;

        require(psEnd < 247, "<247");
        uint256[] memory encArrayMax = new uint256[](42); //42 max
        // u32time|u8id ~ u32time|u8id ~ ...
        // priceInitMap
        uint256 curI = 0;
        uint256 insi = 0;
        uint256 t = 0;
        uint8 xl = 0;

        for (uint i = psStart / 8; i < psEnd / 8 + 1; i++) {
            xl = uint8(udpMap >> (8 * (31 - i)));
            if (xl < 1) continue;

            if (xl & 0x8 > 0) {
                encArrayMax[curI] =
                    encArrayMax[curI] |
                    ((self[(t = 32 * i + 0)] << 8) | t);
                if (insi == 5) {
                    curI += 1;
                    insi = 0;
                } else insi += 1;
            }
            if (xl & 0x4 > 0) {
                encArrayMax[curI] =
                    encArrayMax[curI] |
                    ((self[(t = 32 * i + 1)] << 8) | t);
                if (insi == 5) {
                    curI += 1;
                    insi = 0;
                } else insi += 1;
            }
            if (xl & 0x2 > 0) {
                encArrayMax[curI] =
                    encArrayMax[curI] |
                    ((self[(t = 32 * i + 2)] << 8) | t);
                if (insi == 5) {
                    curI += 1;
                    insi = 0;
                } else insi += 1;
            }
            if (xl & 0x1 > 0) {
                encArrayMax[curI] =
                    encArrayMax[curI] |
                    ((self[(t = 32 * i + 3)] << 8) | t);
                if (insi == 5) {
                    curI += 1;
                    insi = 0;
                } else insi += 1;
            }
        }

        uint256[] memory realArray = new uint256[](curI + 1); //36 max
        for (uint i = 0; i < realArray.length; i++)
            realArray[i] = encArrayMax[i];

        return realArray;
    }

    function leftNonZeroU16(uint16 iVal) internal pure returns (uint256 baseI) {
        if (iVal == 0) return 0;
        if (iVal > 255) {
            iVal = iVal >> 8;
            baseI += 8;
        }
        if (iVal > 15) {
            baseI += 4;
            iVal = iVal >> 4;
        }
        if (iVal > 3) {
            baseI += 2;
            iVal = iVal >> 2;
        }
        if (iVal > 1) {
            baseI += 1;
            iVal = iVal >> 1;
        }
        baseI += iVal;
    }

    function rightNonZeroU16(
        uint16 iVal
    ) internal pure returns (uint256 baseI) {
        if (iVal == 0) return 0;

        if (uint8(iVal) < 1) {
            iVal = iVal >> 8;
            baseI += 8;
        }
        iVal = uint8(iVal);

        if (iVal & 0xF > 0) {
            iVal = iVal & 0xF;
        } else {
            baseI += 4;
            iVal = iVal >> 4;
        }
        if (iVal & 0x3 > 0) {
            iVal = iVal & 0x3;
        } else {
            baseI += 2;
            iVal = iVal >> 2;
        }
        if (iVal & 0x1 > 0) {
            iVal = iVal & 0x1;
        } else {
            baseI += 1;
            iVal = iVal >> 1;
        }
        baseI += iVal; // > 0 ? 0 : 1;
    }

    function setRangeMap(
        uint256 updMap,
        uint256 locLeft,
        uint256 locRight
    ) internal pure returns (uint256) {
        if (locLeft < locRight) {
            require(locRight < 255, "xrge");
            uint256 val = ((1 << uint256(locRight - locLeft + 1)) - 1) <<
                (255 - locRight);
            updMap = updMap & (~val);
        }
        updMap = updMap | (1 << (255 - locLeft));

        return updMap;
    }

    function setSingleMap(
        uint256 updMap,
        uint256 loc
    ) internal pure returns (uint256) {
        updMap = updMap | (1 << (255 - loc));
        return updMap;
    }

    function nextLeftUpdatedSlot(
        uint256 updMap,
        int256 startSlot
    ) internal pure returns (uint256 l) {
        l = 0;
        for (int256 stId = 0; stId < startSlot / 16 + 1; stId++) {
            int256 shift = 255 - startSlot + stId * 16;
            uint16 slotMp = shift >= 0
                ? uint16(updMap >> uint256(shift))
                : uint16(updMap << uint256(-shift));

            if (slotMp > 0) {
                l = uint256(
                    startSlot - stId * 16 - int256(rightNonZeroU16(slotMp) - 1)
                );
                break;
            }
        }
    }

    //current slot not calculated.
    function nextRightUpdatedSlot(
        uint256 updMap,
        uint256 startSlot //247 slot max
    ) internal pure returns (uint256 r) {
        r = 256;
        if (startSlot > 254) return r;

        for (uint256 stId = 0; stId < (255 - startSlot) / 16 + 1; stId++) {
            int256 shift = 255 - int256(startSlot + (stId + 1) * 16);

            uint16 slotMp = shift >= 0
                ? uint16(updMap >> uint256(shift))
                : uint16(updMap << uint256(-shift));

            if (slotMp > 0) {
                r =
                    uint256(startSlot + stId * 16) +
                    (17 - leftNonZeroU16(slotMp));
                break;
            }
        }
    }

    function printInt(string memory str, int val) internal pure {
        if (val > 0) console.log(str, "+", uint256(val));
        else console.log(str, "-", uint256(-val));
    }

    function token0to1NoSpl(
        uint256 _amount0,
        uint256 _sqrtPriceX96
    ) internal pure returns (uint256) {
        return
            FullMath.mulDiv(_sqrtPriceX96 * _sqrtPriceX96, _amount0, 1 << 192);
    }

    function token1to0NoSpl(
        uint256 _amount1,
        uint256 _sqrtPriceX96
    ) internal pure returns (uint256) {
        return
            FullMath.mulDiv(1 << 192, _amount1, _sqrtPriceX96 * _sqrtPriceX96);
    }

    function iNdPosMap(
        uint256[70] storage self,
        uint16 iNum,
        uint16 iNumD,
        uint256 dPosCount
    ) internal {
        if (iNum == iNumD) return;
        uint256 mapI = iNum / 256;
        uint256 iMap = self[mapI] | (1 << (255 - (iNum % 256)));
        if (dPosCount < 2) {
            uint256 mapD = iNum / 256;
            if (mapI == mapD) {
                self[mapI] = iMap & ~(1 << (255 - (iNumD % 256)));
            } else {
                self[mapI] = iMap;
                self[mapD] = self[mapD] & ~(1 << (255 - (iNumD % 256)));
            }
        } else {
            self[mapI] = iMap;
        }
    }

    function iPosMap(
        uint256[70] storage self,
        uint16 iNum,
        uint256 dPosCount
    ) internal {
        if (dPosCount > 0) return;
        uint256 mapI = iNum / 256;
        self[mapI] = self[mapI] | (1 << (255 - (iNum % 256)));
    }

    function dPosMap(
        uint256[70] storage self,
        uint16 dNum,
        uint256 dPosCount
    ) internal {
        if (dPosCount > 1) return;
        uint256 mapD = dNum / 256;
        self[mapD] = self[mapD] & ~(1 << (255 - (dNum % 256)));
    }

    function minU16(uint256[] memory pids) internal pure returns (uint256 val) {
        val = 65535;
        for (uint i = 0; i < pids.length; i++) {
            if (pids[i] < val) val = pids[i];
        }
    }

    function maxU16(uint256[] memory pids) internal pure returns (uint256 val) {
        val = 65535;
        for (uint i = 0; i < pids.length; i++) {
            if (pids[i] > val || val > 17747) val = pids[i];
        }
    }

    function prArray(
        uint256[247] storage self,
        uint256 prStart,
        uint256 prEnd
    ) internal view returns (uint256[] memory) {
        uint256 s = prToPs(prStart);
        uint256 e = prToPs(prEnd);
        uint256 l = e.sub(s, "e<s") + 1;

        uint256[] memory ar = new uint256[](l);

        for (uint i = 0; i < l; i++) {
            ar[i] = self[s + i];
            if (ar[i] < 1)
                ar[
                    i
                ] = 276069985512049908241159041501274605055310715980014228921659870958059600001;
        }
        return ar;
    }

    //trade position range part
    function tickToPos(int24 tick) internal pure returns (uint16) {
        return uint16(uint256(tick + 887272) / PRICE_SPACING);
    }

    function isPosActive(
        uint256 map,
        uint256 posInMap
    ) internal pure returns (bool) {
        return (map & (1 << posInMap)) > 0;
    }

    function XXXXsetActive(uint256[70] storage self, uint16 pos) internal {
        uint16 posM = pos / 256;
        uint16 posInMap = pos % 256;

        uint256 mp = self[posM];
        if (isPosActive(mp, posInMap)) {
            // do nothing to save gas
        } else {
            self[posM] = (mp | (1 << posInMap));
        }
    }

    function XXXXsetInactive(uint256[70] storage self, uint16 pos) internal {
        uint16 posM = pos / 256;
        uint16 posInMap = pos % 256;
        uint256 mp = self[posM];
        if (isPosActive(mp, posInMap)) {
            self[posM] = (mp & (~(1 << posInMap)));
        }
    }

    function posResvDelta(
        mapping(uint128 => uint256) storage self,
        uint128 entryPos,
        uint256 reserve,
        bool increase
    ) internal {
        if (increase) {
            self[entryPos] += reserve;
            uint128 posM = entryPos / 256 + 1000000;
            uint256 posInMap = entryPos % 256;
            uint256 mp = self[posM];
            self[posM] = (mp | (1 << posInMap));
        } else {
            self[entryPos] -= reserve;
            if (self[entryPos] < 1) {
                uint128 posM = entryPos / 256 + 1000000;
                uint256 posInMap = entryPos % 256;
                uint256 mp = self[posM];
                if (isPosActive(mp, posInMap)) {
                    self[posM] = (mp & (~(1 << posInMap)));
                }
            }
        }
    }

    function spread(
        uint256 rPrice,
        uint256 cPrice
    ) internal pure returns (int32) {
        int256 ratio = int256((1000000 * rPrice) / cPrice);
        return int32((ratio * ratio - 1000000000000) / 1000000);
    }
}
