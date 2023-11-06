// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "../libraries/TradeMath.sol";
import '../libraries/FullMath.sol';
import '../libraries/FixedPoint128.sol';
import '../libraries/TransferHelper.sol';
import '../libraries/TickMath.sol';
import '../libraries/LiquidityMath.sol';
import '../libraries/SqrtPriceMath.sol';
import '../libraries/SwapMath.sol';
import '../libraries/PoolAddress.sol';

interface IFactory{
    function spotPoolDeployer() external view returns (address);
}

contract TestHelper {
    using SafeMath for uint256;
    
    // sqrtPriceX96 = sqrt(price) * 2 ** 96
    // realPrice = sPx96 * sPx96 / (2**192) * (10 ** ( decimals(0) - decimals(1) ) )
    //sqrtPriceX96 = realPrice * (2**192) / (10 ** ( decimals(0) - decimals(1) ) 

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

    function getPriceVariance(bool _long0, uint256 _openSqrtX96, uint256 _closeSqrtX96) external pure returns (int256){
        (bool hasProfit, uint256 delta) = TradeMath.getDelta(_long0, _openSqrtX96, _closeSqrtX96, 1000000);
        return hasProfit ? int256(delta) : -int256(delta);
    }

    function sqx96(uint256 _token0Amount, uint256 _token1Amount) external pure returns (uint256){
        return sqrt((_token1Amount << 192).div(_token0Amount));
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
        return TradeMath.tickTo(tick);
    }

    function ticc(
        int24 tick)public pure returns (int24){
        return (tick / 600) * 600 - (tick < 0 ? 600 : 0);
    }

    function psToPr(
        uint256 priceSlot
    ) public pure returns (uint32[] memory priceList) {
        return TradeMath.psToPrList(priceSlot);
    }

    function prToPs(
        uint256[] memory pList
    ) public pure returns (uint256 priceSlot) {
        return TradeMath.prToPs(pList);
    }

    function updatePs(
        uint256 priceSlot,
        uint256 prId,
        uint256 price
    ) public pure returns (uint256) {
        return TradeMath.updatePs(priceSlot, prId, price);
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

    function leftNonZeroU16(
        uint16 iVal
    ) external pure returns (uint256 baseI){
        return TradeMath.leftNonZeroU16(iVal);
    }
    function rightNonZeroU16(
        uint16 iVal
    ) external pure returns (uint256 baseI){
        return TradeMath.rightNonZeroU16(iVal);
    }



    function genMap(
        uint256[] memory lst
    ) external pure returns (uint256 mp){
        for(uint i = 0; i < lst.length; i++){
            mp = mp | uint256(1 << (255 -lst[i]) );
        }
    }


    function nextLeftUpdatedSlot(
        uint256 updMap,
        int256 startSlot
    ) external pure returns (uint256){
        return TradeMath.nextLeftUpdatedSlot(updMap, startSlot);
    }

    function nextRightUpdatedSlot(
        uint256 updMap,
        uint256 startSlot
    ) external pure returns (uint256){
        return TradeMath.nextRightUpdatedSlot(updMap, startSlot);
    }


    function setRangeMap(
        uint256 updMap,
        uint256 locLeft,
        uint256 locRight
    ) external pure returns (uint256) {
        return TradeMath.setRangeMap(updMap, locLeft, locRight);
    }


    function setSingleMap(
        uint256 updMap,
        uint256 loc
    ) external pure returns (uint256) {
        return TradeMath.setSingleMap(updMap, loc);
    }

}