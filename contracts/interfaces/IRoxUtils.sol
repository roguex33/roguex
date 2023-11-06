// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;
pragma abicoder v2;

import "../libraries/TradeData.sol";

interface IRoxUtils {
    function positionFeeBasisPoint() external view returns (uint256);
    function marginFeeBasisPoint() external view returns (uint256);


    function getSqrtTwapX96(
        address spotPool
    ) external view returns (uint160 sqrtPriceX96);


    function nextInitializedTickWithinOneWord(
        address spotPool,
        int24 tick,
        bool lte,
        int24 tickSpacing
    ) external view returns (int24 next, bool initialized);

    function estimate(
        address spotPool,
        bool zeroForOne,
        bool usingLiq,
        int256 amountSpecified
    ) external  view  returns (uint160 sqrtPrice, uint256 amount, int24 endTick);
   
    function fdFeePerS( ) external view returns (uint256);

    function getLiqDetails(
        address spotPool,
        int24 tickStart,
        uint256 amount
     ) external view returns (int256[] memory, int24 tickEnd);


    function getLiqs(
        address spotPool,
        int24 startPrTick,
        uint256 resvAmount,
        bool is0
    ) external view returns (uint256[] memory liqL, uint256 liqSum, uint256 ltLiq, uint256 tkSum);


    function getClosePrice(
            address spotPool,
            bool long0,
            uint256 sizeDelta
    ) external view returns (uint256);

    function gClosePrice(
            address roxPerpPool,
            uint256 sizeDelta,
            TradeData.TradePosition memory tP
    ) external view returns (uint256);
       
    function getOpenPrice(
            address roxPerpPool,
            bool long0, 
            uint256 sizeDelta) external view returns (uint256 openPriceSqrtX96);

    function gOpenPrice(
        address roxPerpPool,
        bool long0,
        uint256 sizeDelta) external view returns (uint160 openPrice, int24 openTick, uint160 curPrice, int24 curTick);
}