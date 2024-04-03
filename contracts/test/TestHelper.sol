// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "../libraries/TradeMath.sol";
import "../libraries/PriceRange.sol";
import '../libraries/FullMath.sol';
import '../libraries/FixedPoint128.sol';
import '../libraries/TransferHelper.sol';
import '../libraries/TickMath.sol';
import '../libraries/LiquidityMath.sol';
import '../libraries/SqrtPriceMath.sol';
import '../libraries/SwapMath.sol';
import '../libraries/PoolAddress.sol';
import '../libraries/TickRange.sol';

import '../interfaces/IRoxSpotPool.sol';

import "hardhat/console.sol";


interface IFactory{
    function spotPoolDeployer() external view returns (address);
}

interface IHyperPool{
    function getDepositAmountRatio() external view returns (uint256);
}

library Math {
    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
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

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow, so we distribute
        return (a / 2) + (b / 2) + (((a % 2) + (b % 2)) / 2);
    }
}

library PriceUtils {
    using SafeMath for uint256;

    function getPriceByTick(int24 _tick) internal pure returns (uint256 price) {
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(_tick);
        price = FullMath.mulDiv(
            uint256(sqrtPrice).mul(1e18),
            uint256(sqrtPrice).mul(1e18),
            2 ** (96 * 2)
        );
    }

    function getTickUpperAndLower(
        uint256 price,
        uint256 priceRange,
        uint256 rangeSion
    ) internal pure returns (int24 adjustTickUpper, int24 adjustTickLower) {
        uint160 sqrtPriceUpper = uint160(
            FullMath.mulDiv(
                Math.sqrt(
                    FullMath.mulDiv(price, priceRange.add(rangeSion), rangeSion)
                ),
                2 ** 96,
                1e18
            )
        );
        uint160 sqrtPriceLower = uint160(
            FullMath.mulDiv(
                Math.sqrt(
                    FullMath.mulDiv(price, rangeSion, rangeSion + priceRange)// FullMath.mulDiv(price, rangeSion - priceRange, rangeSion)
                ),
                2 ** 96,
                1e18
            )
        );
        adjustTickUpper = TickMath.getTickAtSqrtRatio(sqrtPriceUpper);
        adjustTickUpper = (adjustTickUpper / 600) * 600 + 600;
        adjustTickLower = TickMath.getTickAtSqrtRatio(sqrtPriceLower);
        adjustTickLower = (adjustTickLower / 600) * 600 - 600;
    }


    function getSpli(
        uint256 price,
        uint256 priceRange,
        uint256 rangeSion,
        uint128 liquidity
    ) internal pure returns (uint256) {
        (int24 adjustTickUpper, int24 adjustTickLower) = getTickUpperAndLower(
            price,
            priceRange,
            rangeSion
        );
        uint160 lastPrice = uint160(
            FullMath.mulDiv(Math.sqrt(price), 2 ** 96, 1e18)
        );
        uint160 sqrtPriceUpper = TickMath.getSqrtRatioAtTick(adjustTickUpper);
        uint160 sqrtPriceLower = TickMath.getSqrtRatioAtTick(adjustTickLower);
        uint256 depost0 = SqrtPriceMath.getAmount0Delta(
            lastPrice,
            sqrtPriceUpper,
            liquidity,
            true
        );
        uint256 depost1 = SqrtPriceMath.getAmount1Delta(
            sqrtPriceLower,
            lastPrice,
            liquidity,
            true
        );
        return FullMath.mulDiv(depost1, 1e36, depost0);
    }
}

contract TestHelper {
    using SafeMath for uint256;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint256 internal constant Q192 = 1 << 192;
    uint256 public constant PRECISION = 1e36;
    
    // sqrtPriceX96 = sqrt(price) * 2 ** 96
    // realPrice = sPx96 * sPx96 / (2**192) * (10 ** ( decimals(0) - decimals(1) ) )
    //sqrtPriceX96 = realPrice * (2**192) / (10 ** ( decimals(0) - decimals(1) ) 

    // zeroForOne: true for token0 to token1, false for token1 to token0
    function rightBoundaryTick(int24 tick) external pure returns (int24) {
        return TickRange.rightBoundaryTick(tick);
    }


    function leftBoundaryTickWithin(int24 tick) external pure returns (int24) {
        return TickRange.leftBoundaryTickWithin(tick);
    }



    function computeAddress(bytes32 _hash, address factory, address token0, address token1, uint24 fee) external view returns (address){
        return address(
            uint256(
                keccak256(
                    abi.encodePacked(
                        hex'ff',
                        IFactory(factory).spotPoolDeployer(),
                        keccak256(abi.encode(token0, token1, fee)),
                        _hash
                    )
                )
            )
        );

    }

    function token0t1NoSpl(
        address _spotPool,
        uint256 _amount0
    ) public view returns (uint256) {
        // protect from flash attach
        (uint160 price, , , , , , ) = IRoxSpotPool(_spotPool).slot0();
        return TradeMath.token0to1NoSpl(_amount0, uint256(price));
    }

    function token0t1NoSplPrice(
        uint256 _amount0,
        uint160 price
    ) public pure returns (uint256) {
        // protect from flash attach
        return TradeMath.token0to1NoSpl(_amount0, uint256(price));
    }

    function token1t0NoSpl(
        address _spotPool,
        uint256 _amount1
    ) public view returns (uint256) {
        // protect from flash attach
        (uint160 price, , , , , , ) = IRoxSpotPool(_spotPool).slot0();
        return TradeMath.token1to0NoSpl(_amount1, uint256(price));
    }

    function token1t0NoSplPrice(
        uint256 _amount1,
        uint160 price
    ) public pure returns (uint256) {
        // protect from flash attach
        return TradeMath.token1to0NoSpl(_amount1, uint256(price));
    }


    function getDepositAmount1(uint256 amount0, address hyperPool) external view returns(uint256){
        uint ratio = IHyperPool(hyperPool).getDepositAmountRatio();
        return FullMath.mulDiv(amount0, ratio, PRECISION);
    }




    function getPriceVariance(bool _long0, uint256 _openSqrtX96, uint256 _closeSqrtX96) external pure returns (uint256 profitDelta){

        uint256 _openPriceX96 = FullMath.mulDiv(
            _openSqrtX96,
            _openSqrtX96,
            Q96
        );
        uint256 _closePriceX96 = FullMath.mulDiv(
            _closeSqrtX96,
            _closeSqrtX96,
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
            profitDelta = FullMath.mulDiv(1000000, priceDelta, _openPriceX96);
            // hasProfit = _closePriceX96 > _openPriceX96;
            // priceDelta = FullMath.mulDiv(1000000, priceDelta, _openPriceX96);
        } else {
            // hasProfit = _openPriceX96 > _closePriceX96;
            profitDelta = FullMath.mulDiv(1000000, priceDelta, _closePriceX96);
            // priceDelta = FullMath.mulDiv(1000000, priceDelta, _closePriceX96);
        }

        // ( , uint256 delta) = TradeMath.getDelta(_long0, _openSqrtX96, _closeSqrtX96, 1000000);
        // return delta;//hasProfit ? int256(delta) : -int256(delta);
    }

    // function sqx96(uint256 _token0Amount, uint256 _token1Amount) external pure returns (uint256){
    //     return sqrt((_token1Amount << 192).div(_token0Amount));
    // }
    function sqx96(uint256 _token0Amount, uint256 _token1Amount) external pure returns (uint256){
        // amount0 = q192 * amount1 / p*p
        return sqrt(FullMath.mulDiv(Q192, _token1Amount, _token0Amount));
    }



    function sqrt(uint x) public pure returns (uint y) {
        uint z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function tickTo(
        int24 tick
    ) public pure returns (uint16 pr, uint16 ps){
        return PriceRange.tickTo(tick);
    }

    function ticc(
        int24 tick, bool _is0)public pure returns (int24){
        return PriceRange.rightBoundaryTick(tick) - (_is0 ? 0 : 600);
    }

    // function psToPr(
    //     uint256 priceSlot
    // ) public pure returns (uint32[] memory priceList) {
    //     return PriceRange.psToPrList(priceSlot);
    // }

    // function prToPs(
    //     uint256[] memory pList
    // ) public pure returns (uint256 priceSlot) {
    //     return psToPrList.prToPs(pList);
    // }

    // function updatePs(
    //     uint256 priceSlot,
    //     uint256 prId,
    //     uint256 price
    // ) public pure returns (uint256) {
    //     return psToPrList.updatePs(priceSlot, prId, price);
    // }

    function prArrayToPs(
        uint256[] memory pList
    ) internal pure returns (uint256 priceSlot) {
        require(pList.length == 8, "L!=8");
        // priceSlot = 0x1FFFFF & pList[11];
        for (uint i = 0; i < 8; i++) {
            // priceSlot = priceSlot << 21;
            priceSlot = priceSlot | ( (0xFFFFFFFF & pList[i]) << (224 - i * 32));
        }
    }




    function token0toLiq(
        int24 tickLower,
        int24 tickUpper,
        uint256 tokenAmount
    ) external pure returns (int128 liquidityDelta) {
        liquidityDelta = int128(SqrtPriceMath.getLiquidityAmount0(
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            tokenAmount,
            false
        ));
    }

    function LiqToToken0(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDelta
    ) external pure returns (uint256 amount0) {
        amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(tickLower),
                    TickMath.getSqrtRatioAtTick(tickUpper),
                    liquidityDelta,
                    true
                );
    }

    function token1toLiq(
        int24 tickLower,
        int24 tickUpper,
        uint256 tokenAmount
    ) external pure returns (int128 liquidityDelta) {
        liquidityDelta = int128(SqrtPriceMath.getLiquidityAmount1(
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            tokenAmount,
            false
        ));
    }

    function LiqToToken1(
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) external pure returns (int256 amount1) {
        amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(tickLower),
                    TickMath.getSqrtRatioAtTick(tickUpper),
                    liquidityDelta
                );
    }

    // function leftNonZeroU16(
    //     uint16 iVal
    // ) external pure returns (uint256 baseI){
    //     return TradeMath.leftNonZeroU16(iVal);
    // }
    // function rightNonZeroU16(
    //     uint16 iVal
    // ) external pure returns (uint256 baseI){
    //     return TradeMath.rightNonZeroU16(iVal);
    // }

    function psToPrList(
        uint256 priceSlot
    ) internal pure returns (uint32[] memory priceList) {
        priceList = new uint32[](8);
        for (uint i = 0; i < 8; i++) {
            priceList[i] = uint32(priceSlot >> (224 - (32 * i)));
        }
    }

    function genMap(
        uint256[] memory lst
    ) external pure returns (uint256 mp){
        for(uint i = 0; i < lst.length; i++){
            mp = mp | uint256(1 << (255 -lst[i]) );
        }
    }

    function rangeBoundaryTick(int24 tick, bool _is0) external pure returns(int24){
        return PriceRange.rightBoundaryTick(tick) - (_is0 ? 0 : 600);
    }

    function getSqrtRatioAtTick(int24 tick) external pure returns(uint256){
        return TickMath.getSqrtRatioAtTick(tick);
    }
    function getTickAtSqrtRatio(uint160 sqrtPrice) external pure returns(int24){
        return TickMath.getTickAtSqrtRatio(sqrtPrice);
    }

    function round6(int24 tick) external pure returns(int24){
        return (tick / 600) * 600;
    }

    function getTikcUpperAndLower(
        int24 tick,
        uint256 priceRange,
        uint256 rangeSion
    ) public view returns (int24 adjustTickUpper, int24 adjustTickLower) {

        uint256 price = PriceUtils.getPriceByTick(tick);


        uint160 sqrtPriceUpper = uint160(
            FullMath.mulDiv(
                Math.sqrt(
                    FullMath.mulDiv(price, priceRange.add(rangeSion), rangeSion)
                ),
                2 ** 96,
                1e18
            )
        );
        uint160 sqrtPriceLower = uint160(
            FullMath.mulDiv(
                Math.sqrt(
                    FullMath.mulDiv(price, rangeSion - priceRange, rangeSion)
                    // FullMath.mulDiv(price, rangeSion, rangeSion + priceRange)
                ),
                2 ** 96,
                1e18
            )
        );
        adjustTickUpper = TickMath.getTickAtSqrtRatio(sqrtPriceUpper);
        adjustTickUpper >= 0 ? 
            console.log("originalTickUpper : ", uint256(adjustTickUpper))
            :
            console.log("originalTickUpper : -", uint256(-adjustTickUpper));

        // adjustTickUpper = TickMath.getTickAtSqrtRatio(sqrtPriceUpper);
        // adjustTickLower = TickMath.getTickAtSqrtRatio(sqrtPriceLower);
        tick >= 0 ? 
            console.log("currentTick     : ", uint256(tick))
            :
            console.log("currentTick     : -", uint256(-tick));

        tick = ((tick / 600) * 600 ) - (tick > 0 ? 0 : 600 );
        tick >= 0 ? 
            console.log("currentTick     : ", uint256(tick))
            :
            console.log("currentTick     : -", uint256(-tick));

        int24 gapI = (adjustTickUpper - tick + 600) / 600;
        console.log("gap : ", uint(gapI) * 600);
        // tick = (tick / 600) * 600 - tick > 0 ? 0 : 600;
        adjustTickUpper = tick + 600 * gapI + 600;
        adjustTickLower = tick - 600 * gapI;


        adjustTickUpper >= 0 ? 
            console.log("adjustTickUpper : ", uint256(adjustTickUpper))
            :
            console.log("adjustTickUpper : -", uint256(-adjustTickUpper));

        adjustTickLower >= 0 ? 
            console.log("adjustTickLower : ", uint256(adjustTickLower))
            :
            console.log("adjustTickLower : -", uint256(-adjustTickLower));

        console.log("Upper : ", uint256(adjustTickUpper - tick ));
        console.log("Lower : ", uint256(tick - adjustTickLower));

        adjustTickUpper = (adjustTickUpper / 600) * 600 + 600;
        adjustTickLower = (adjustTickLower / 600) * 600 - 600;
    }


    // function nextLeftUpdatedSlot(
    //     uint256 updMap,
    //     int256 startSlot
    // ) external pure returns (uint256){
    //     return TradeMath.nextLeftUpdatedSlot(updMap, startSlot);
    // }

    // function nextRightUpdatedSlot(
    //     uint256 updMap,
    //     uint256 startSlot
    // ) external pure returns (uint256){
    //     return TradeMath.nextRightUpdatedSlot(updMap, startSlot);
    // }


    // function setRangeMap(
    //     uint256 updMap,
    //     uint256 locLeft,
    //     uint256 locRight
    // ) external pure returns (uint256) {
    //     return TradeMath.setRangeMap(updMap, locLeft, locRight);
    // }


    // function setSingleMap(
    //     uint256 updMap,
    //     uint256 loc
    // ) external pure returns (uint256) {
    //     return TradeMath.setSingleMap(updMap, loc);
    // }

    // function getPriceX96FromSqrtPriceX96(
    //     uint160 sqrtPriceX96
    // ) internal pure returns (uint256 priceX96) {
    //     return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
    // }

    function reverse(
        uint[] memory _array
    ) public pure returns (uint[] memory) {
        uint length = _array.length;
        uint[] memory reversedArray = new uint[](length);
        uint j = 0;
        for (uint i = length; i >= 1; i--) {
            reversedArray[j] = _array[i - 1];
            j++;
        }
        return reversedArray;
    }
}