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
    function pUtils() external view returns (address);

    function collectPosFee(
        uint256 size,
        address spotPool
    ) external view returns (uint128);

    function getSqrtTwapX96(
        address spotPool
    ) external view returns (uint160 sqrtPriceX96);

    function getTwapTickUnsafe(address _spotPool, uint32 _sec) external view returns (int24 tick);      

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


    function getLiqArray(
        address spotPool,
        bool isToken0,
        uint256 amount
    ) external view returns (uint256[] memory, uint128,  uint256, int24);

    function availableReserve(
        address _spotPool,
        bool _l0, bool _l1
        ) external view returns (uint256 r0, uint256 r1);
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

    function getDelta(
        address _spotPool,
        uint256 _closePriceSqrtX96,
        TradeData.TradePosition memory tP) external view returns (bool hasProfit, uint128 profitDelta, uint128 factorDelta);

    function gOpenPrice(
        address roxPerpPool,
        uint256 sizeDelta,
        bool long0,
        bool isCor) external view returns (uint160 openPrice, int24 openTick, uint160 twapPrice, uint24 spread);

    function modifyPoolSetting(
        address _spotPool, 
        uint8 _maxLeverage,
        uint16 _spotThres,
        uint16 _perpThres,
        uint16 _setlThres,
        uint32 _fdFeePerS,
        uint32 _twapTime,
        uint8 _countMin,
        bool _del
        ) external;

    function gFdPs(
        address _spotPool,
        address _posnPool,
        uint256 _reserve0,
        uint256 _reserve1
    ) external view returns (uint32, uint32);
}