// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;
pragma abicoder v2;

import "../libraries/TradeData.sol";
import '../libraries/PriceRange.sol';


interface IRoxPerpPool {
   
    function reserve0() external view returns (uint256);
    function reserve1() external view returns (uint256);
    function sBalance0() external view returns (uint256);
    function sBalance1() external view returns (uint256);
    function globalLong1() external view returns (uint256);
    function globalLong0() external view returns (uint256);
    function prUpdTime(uint) external view returns (uint256);

    function closeMinuteMap0(uint32) external view returns (uint256);
    function closeMinuteMap1(uint32) external view returns (uint256);

    function tPid(bool l0) external view returns (uint256);
    // function pKeys(bool l0) external view returns (bytes32[] memory);
    
    

    // function priceSlot(uint256) external view returns (uint256);
    // function openLiquidity() external view returns (uint256, uint256);


    function increasePosition(
        address _account,
        uint256 _liquidityDelta,
        bool _long0
    ) external returns (bytes32, uint256);

    function decreasePosition(
        // address _account,
        // bool _long0,
        bytes32 _key,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        address _feeRecipient
    ) external returns (bool, bool, uint256, address);

    function token0() external view returns (address);
    function token1() external view returns (address);
    function spotPool() external view returns (address);


    function getPositionByKey(
        bytes32 _key
    ) external view returns (TradeData.TradePosition memory);

  
    function priceSlot(
        uint256 psId
    ) external view returns (uint256);

    function prInfo(
        uint256 timePr
    ) external view returns (PriceRange.Info memory);

    function rgFeeSlot(
    ) external view returns (TradeData.RoguFeeSlot memory);
  
    function encodePriceSlots(
        uint256 prStart, uint256 prEnd
    ) external view returns (uint256[] memory);
    
    function encodeTimeSlots(
        uint256 prStart, uint256 prEnd
    ) external view returns (uint256[] memory);
    
    function updateSwapFee(
        int24 tick,
        bool zeroForOne,
        uint256 feeX128
    ) external;

    // function prPrice(
    //     uint pr
    //     ) external view returns (uint256);

}