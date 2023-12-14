// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;
pragma abicoder v2;

import "../libraries/TradeData.sol";

interface IRoxUtils {
    function spotThres(address spotPool) external view returns (uint256);
    function perpThres(address spotPool) external view returns (uint256);
    function setlThres(address spotPool) external view returns (uint256);
    function fdFeePerS(address spotPool) external view returns (uint256);
    function maxLeverage(address spotPool) external view returns(uint256);

    function collectPosFee(
        uint256 size,
        address spotPool
    ) external view returns (uint256);

    function getSqrtTwapX96(
        address spotPool
    ) external view returns (uint160 sqrtPriceX96);

    function validPosition(
        uint256 collateral,
        uint256 size,
        address spotPool
    ) external view returns (bool);

    function nextInitializedTickWithinOneWord(
        address spotPool,
        int24 tick,
        bool lte,
        int24 tickSpacing
    ) external view returns (int24 next, bool initialized);

    function estimate(
        address spotPool,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 fee
    ) external view returns (uint160 sqrtPrice, int256 amount0, int256 amount1, int24 endTick, uint128 endLiq);
   

    function weth( ) external view returns (address);


    function getLiquidityArraySpecifiedStart(
        address spotPool,
        int24 curTick,
        int24 tickStart,
        bool isToken0,
        uint256 amount
    ) external  view returns (uint256[] memory, uint128,  uint256);


    // function getLiqs(
    //     address spotPool,
    //     int24 curTick,
    //     int24 startPrTick,
    //     uint256 resvAmount,
    //     bool is0
    // ) external view returns (uint256[] memory liqL, uint256 liqSum, uint256 ltLiq, uint256 tkSum);


    function getClosePrice(
            address spotPool,
            bool long0,
            uint256 sizeDelta,
            bool isCor
    ) external view returns (uint256);

    function gClosePrice(
            address roxPerpPool,
            uint256 sizeDelta,
            TradeData.TradePosition memory tP,
            bool isCor
    ) external view returns (uint160 closePrice, uint160 twapPrice, uint24 closeSpread) ;
       
    // function getOpenPrice(
    //         address roxPerpPool,
    //         bool long0, 
    //         uint256 sizeDelta) external view returns (uint256 openPriceSqrtX96);

    function gOpenPrice(
        address roxPerpPool,
        uint256 sizeDelta,
        bool long0,
        bool isCor) external view returns (uint160 openPrice, int24 openTick, uint160 twapPrice, uint24 spread);
}