// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "../libraries/TickMath.sol";
import "../libraries/BitMath.sol";
import "../libraries/SqrtPriceMath.sol";
import "./FullMath.sol";

library PosRange {
    using SafeMath for uint256;
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint256 public constant ltprec = 1e12;
    uint256 public constant PS_SPACING = 100000;
    uint256 public constant PR_SPACING = 600;
    uint256 public constant PRICE_SPACING = 100; //1.0001^100 > 1%   17745 ranges > 70x 256 bit map

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

    function posResvDelta(
        mapping(uint128 => uint256) storage self,
        uint128 entryPos,
        uint256 reserveDelta,
        bool increase
    ) internal {
        if (increase){
            self[entryPos] += reserveDelta;
            uint128 posM = entryPos / 256 + 1000000;
            uint256 posInMap = entryPos % 256;
            uint256 mp = self[posM];
            self[posM] = (mp | (1 << posInMap));
            
        }
        else{
            self[entryPos] -= reserveDelta;//todo: check >
            if (self[entryPos] < 1){
                uint128 posM = entryPos / 256 + 1000000;
                uint256 posInMap = entryPos % 256;
                uint256 mp = self[posM];
                if (isPosActive(mp, posInMap)) {
                    self[posM] = (mp & (~(1 << posInMap)));
                }
            }
        }
    }

    function maxPos(
        mapping(uint128 => uint256) storage self
    ) internal view returns (uint16 max) {
        max = 65535;
        for (uint128 i = 1000069; i >= 1000000; i--) {
            if (self[i] > 0) {
                max = uint16((i-1000000) * 256 + BitMath.mostSignificantBit(self[i]));
                return max;
            }
            continue;
        }
    }

    function minPos(
        mapping(uint128 => uint256) storage self
    ) internal view returns (uint16 min) {
        min = 65535;
        for (uint128 i = 1000000; i < 1000070; i++) {
            if (self[i] > 0) {
                min = uint16((i-1000000) * 256 + BitMath.leastSignificantBit(self[i]));
                return min;
            }
            continue;
        }
    }


}
