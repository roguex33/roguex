// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import './pool/IRoxSpotPoolImmutables.sol';
import './pool/IRoxSpotPoolState.sol';
import './pool/IRoxSpotPoolDerivedState.sol';
import './pool/IRoxSpotPoolActions.sol';
import './pool/IRoxSpotPoolEvents.sol';

/// @title The interface for a Spot Pool
/// @notice A spot pool facilitates swapping and automated market making between any two assets that strictly conform
/// to the ERC20 specification
/// @dev The pool interface is broken up into many smaller pieces
interface IRoxSpotPool is
    IRoxSpotPoolImmutables,
    IRoxSpotPoolState,
    IRoxSpotPoolDerivedState,
    IRoxSpotPoolActions,
    IRoxSpotPoolEvents
{
    function roxPerpPool() external view returns (address);
    function roxPosnPool() external view returns (address);
    
    function tInAccum0() external view returns (uint256);
    function tInAccum1() external view returns (uint256);

    function balance0() external view returns (uint256);
    function balance1() external view returns (uint256);

    // function l0rec() external view returns (uint256);
    // function l1rec() external view returns (uint256);

    // function estimateDecreaseLiquidity(
    //     bytes32 key,
    //     uint128 liquidityDelta
    // ) external view returns (uint256 amount0, uint256 amount1);

    function updatePnl(
        int24 tickLower,
        int24 tickUpper,
        int24 slot0tick,
        int128 liquidityDelta
    ) external;

    function burnN(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1);  

    // function collectN(
    //     address recipient,
    //     int24 tickLower,
    //     int24 tickUpper,
    //     uint128 amount0Requested,
    //     uint128 amount1Requested
    // ) external returns (uint128 amount0, uint128 amount1);

    function perpSettle(
        uint256 amount,
        bool is0,
        address recipient
    ) external;

    // function getTwapTickUnsafe(uint32 _sec) external view returns (int24 tick);

    // function availableReserve(
    //     bool _l0, bool _l1
    //     ) external view returns (uint256 r0, uint256 r1);
}
