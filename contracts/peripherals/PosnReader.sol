// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

import "../interfaces/IRoxSpotPool.sol";
import "../interfaces/IRoxPerpPool.sol";
import "../interfaces/IRoxPosnPool.sol";
import "../interfaces/IRoxUtils.sol";
import "../libraries/TradeData.sol";
import "../libraries/TradeMath.sol";
import "../libraries/PosRange.sol";
import "../libraries/LowGasSafeMath.sol";
import "../libraries/FullMath.sol";
import "../libraries/TickMath.sol";
import "../libraries/LiquidityMath.sol";
import "../libraries/SqrtPriceMath.sol";
import "../libraries/PriceRange.sol";
import "../interfaces/INonfungiblePositionManager.sol";
import "../interfaces/IRoguexFactory.sol";


contract PosnReader {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for uint128;

    uint256 public constant RATIO_PREC = 1e6;
    uint256 public constant MAX_LEVERAGE = 80;

    IRoxUtils public roxUtils;
    INonfungiblePositionManager public nftmanager;
    IRoguexFactory public factory;
    
    constructor(address _roguUtils, address _nftmanager, address _factory) {
        roxUtils = IRoxUtils(_roguUtils);
        nftmanager = INonfungiblePositionManager(_nftmanager);
        factory = IRoguexFactory(_factory);
    }

    function estimateDecreaseLiquidity(
        INonfungiblePositionManager.DecreaseLiquidityParams calldata params
    ) external view returns (uint256 amount0, uint256 amount1){

        INonfungiblePositionManager.PositionDisp memory _pos = 
            nftmanager.positions(params.tokenId);
        IRoxSpotPool spotPool = IRoxSpotPool(
                                    factory.getPool(
                                        _pos.token0,
                                        _pos.token1,
                                        _pos.fee
                                    )
                                );
        IRoxPosnPool posnPool = IRoxPosnPool(spotPool.roxPosnPool());

        (
            uint160 sqrtPriceX96,
            int24 tick,
            ,
            ,
            ,
            ,

        ) = spotPool.slot0();

        bytes32 _key = PositionKey.compute(
                        nftmanager.ownerOf(params.tokenId),
                        _pos.tickLower,
                        _pos.tickUpper
                    );

        return posnPool.estimateDecreaseLiquidity(
                _key,
                params.liquidity,
                tick,
                sqrtPriceX96
            );
    }

}
