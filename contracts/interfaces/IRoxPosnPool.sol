// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;
pragma abicoder v2;

import "../libraries/TradeData.sol";
import '../libraries/PriceRange.sol';
import '../libraries/RoxPosition.sol';


interface IRoxPosnPool {
   
    function positions(bytes32 key)
        external
        view
        returns (
            uint128 liquidity,
            uint128 spotFeeOwed0,
            uint128 spotFeeOwed1,
            uint128 perpFeeOwed0,
            uint128 perpFeeOwed1,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function positionsSum(bytes32 key)
        external
        view
        returns ( 
            uint128 liquidity,
            uint256 feeOwed0,
            uint256 feeOwed1,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
    // function updatePosition(
    //     RoxPosition.Position memory position,
    //     address roxPerpPool,
    //     int128 liquidityDelta,
    //     uint160 curSqrtPrice,
    //     int24 tickCur
    // ) external returns (RoxPosition.Position memory, uint256 amount0, uint256 amount1);

 function estimateDecreaseLiquidity(
        bytes32 _key,
        uint128 liquidityDelta,
        int24 tick,
        uint160 sqrtPriceX96
    ) external view returns (uint256 amount0, uint256 amount1);

    function pendingFee(
        bytes32 _key
    ) external view returns (
            uint128 tokenOw0, uint128 tokenOw1,
            uint128 spotFeeOwed0, uint128 spotFeeOwed1, uint128 perpFeeOwed0, uint128 perpFeeOwed1);

    function increaseLiquidity(
        // mapping(bytes32 => Position) storage self,
        // RoxPosition.Position memory position,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        // int24 tickLower,
        // int24 tickUpper,
        uint128 liquidityDelta
    ) external;

    function updateFee(
        bytes32 key
    ) external;

    // function decreaseLiquidity(
    //     bytes32 key,
    //     uint128 liquidityDelta
    // ) external returns (uint32[] memory);
    function decreaseLiquidity(
        bytes32 _key,
        uint128 liquidityDelta,
        int24 tick,
        uint160 sqrtPriceX96
    ) external returns (uint128[] memory liqRatio, uint256 amount0, uint256 amount1);



    function collect(
        bytes32 _key,
        uint128 _amount0Requested,
        uint128 _amount1Requested
        ) external  returns (uint128 amount0, uint128 amount1);


//    function updatePosition(
//         address owner,
//         int24 tickLower,
//         int24 tickUpper,
//         int128 liquidityDelta
//     ) external returns (uint256 amount0, uint256 amount1);
}