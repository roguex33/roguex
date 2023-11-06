// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;
pragma abicoder v2;

import "../libraries/TradeData.sol";
import '../libraries/PriceRange.sol';


interface IPerpRouter {
    function increasePosition(
        address _account,
        address _perpPool,
        uint256 _tokenAmount,
        uint256 _sizeDelta,
        bool _long0,
        uint160 _sqrtPriceX96
    ) external ;

    function decreasePosition(
        address _account,
        address _perpPool,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _long0,
        uint160 _sqrtPriceX96
    ) external ;
}