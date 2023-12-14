// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import "../libraries/TickMath.sol";
import "../libraries/BitMath.sol";
import "../libraries/SqrtPriceMath.sol";
import "../libraries/LowGasSafeMath.sol";
import "./FullMath.sol";

library TradeMath {
    using LowGasSafeMath for uint256;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint256 internal constant Q192 = 1 << 192;

    function weightAve(
        uint256 _weight0,
        uint256 _value0,
        uint256 _weight1,
        uint256 _value1
    ) internal pure returns (uint256) {
        uint256 weightS = _weight0 + _weight1;
        return
            FullMath.mulDiv(_weight0, _value0, weightS) + 
                FullMath.mulDiv(_weight1, _value1, weightS);
    }

    function tkPosition(
        int24 tick
    ) internal pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(tick % 256);
    }


    function liqTrans(
        uint128 entryLiq,
        uint256 entryPrice,
        uint256 curPrice
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
            ? _openPriceX96 - _closePriceX96
            : _closePriceX96 - _openPriceX96;

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

    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function nextPrice(
        uint256 _size,
        uint256 _entryPrice,
        uint256 _nextPrice,
        uint256 _sizeDelta
    ) internal pure returns (uint256) {
        // Calculation:
        // Profit Entry == Profit New Ave Price
        // (curPrice - entryPrice)/entryPrice * entrySize = (curPrice - avePrice)/avePrice * (entrySize + sizeDelta)
        // avePrice = curPrice * entryPrice * (entrySize + deltaSize) / (deltaSize * entryPrice + entrySize * curPrice)
        //                           curPrice * entryPrice 
        //          =  -------------------------------------------------
        //              deltaSize * entryPrice     entrySize * curPrice
        //              ----------------------  +  --------------------
        //              entrySize + deltaSize      entrySize + deltaSize
        //  
        //  > Convert to MulDiv format


        uint256 ampfP = (_entryPrice > _nextPrice ? _nextPrice : _entryPrice) /
            170141183460469231731687303715884105728 +
            1;

        _entryPrice = FullMath.mulDiv(_entryPrice, _entryPrice, ampfP * ampfP); //_entryPrice / ampfP * _entryPrice / ampfP;
        _nextPrice = FullMath.mulDiv(_nextPrice, _nextPrice, ampfP * ampfP); //_nextPrice / ampfP * _nextPrice / ampfP;


        uint256 _sSum = _size + _sizeDelta;
        require(_sSum > 0, "eS");
        uint256 _tpp = FullMath.mulDiv(_entryPrice, _sizeDelta, _sSum) +
            FullMath.mulDiv(_nextPrice, _size, _sSum);

        uint256 nextP = FullMath.mulDiv(_entryPrice, _nextPrice, _tpp);
        nextP = sqrt(nextP) * ampfP;
        return nextP;
    }



    function getPositionKey(
        address _account,
        address _tradePool,
        bool _long0
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _tradePool, _long0));
    }

    // function printInt(string memory str, int val) internal pure {
    //     // if (val > 0) console.log(str, "+", uint256(val));
    //     // else console.log(str, "-", uint256(-val));
    // }

    function token0to1NoSpl(
        uint256 _amount0,
        uint256 _sqrtPriceX96
    ) internal pure returns (uint256) {

        if (_sqrtPriceX96 < 170141183460469231731687303715884105728){
            return
                FullMath.mulDiv(_sqrtPriceX96 * _sqrtPriceX96, _amount0, Q192);
        }else{
            uint256 ampfP = _sqrtPriceX96 / 170141183460469231731687303715884105728 + 1;
            return
                FullMath.mulDiv(FullMath.mulDiv(_sqrtPriceX96, _sqrtPriceX96, ampfP * ampfP), _amount0, Q192 / (ampfP * ampfP));
        }

    }

    function token1to0NoSpl(
        uint256 _amount1,
        uint256 _sqrtPriceX96
    ) internal pure returns (uint256) {

        if (_sqrtPriceX96 < 170141183460469231731687303715884105728){
            return
                FullMath.mulDiv(Q192, _amount1, _sqrtPriceX96 * _sqrtPriceX96);
        }else{
            uint256 ampfP = _sqrtPriceX96 / 170141183460469231731687303715884105728 + 1;
            return
                FullMath.mulDiv(Q192 / (ampfP * ampfP), _amount1, FullMath.mulDiv(_sqrtPriceX96, _sqrtPriceX96, ampfP * ampfP));
        }
    }

}
