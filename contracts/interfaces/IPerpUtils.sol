// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;
pragma abicoder v2;

import "../libraries/TradeData.sol";

interface IPerpUtils {
    function estimateImpact(
        address _spotPool,
        uint256 _estiDelta,
        uint256 _revtDelta,
        bool _long0
    ) external view returns (uint256 spread);

   function estimate(
        address spotPool,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 fee
    ) external view returns (uint160 sqrtPrice, int256 amount0, int256 amount1, int24 endTick, uint128 endLiq);
   
    function nextInitializedTickWithinOneWord(
        address spotPool,
        int24 tick,
        bool lte,
        int24 tickSpacing
    ) external view returns (int24 next, bool initialized);


    // function calLiqSpecifiedAmount0(
    //     address spotPool,
    //     TradeData.LiqCalState memory state,
    //     TradeData.PriceRangeLiq memory prState
    // ) external view returns (uint256[] memory, uint128 endLiq, uint256 liqSum);

    // function calLiqSpecifiedAmount1(
    //     address spotPool,
    //     TradeData.LiqCalState memory state,
    //     TradeData.PriceRangeLiq memory prState
    // ) external view returns (uint256[] memory, uint128 endLiq,  uint256 liqSum);

    function calLiqArray1(
        address spotPool,
        uint256 amountSpecifiedRemaining
    ) external view returns (uint256[] memory, uint128 endLiq, uint256 liqSum, int24 startPr);

    function calLiqArray0(
        address spotPool,
        uint256 amountSpecifiedRemaining
    ) external view returns (uint256[] memory, uint128 endLiq, uint256 liqSum, int24 startPr);
}