// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

library NftData {
    // details about the rox position
    struct Position {
        // the nonce for permits
        uint96 nonce;
        // the address that is approved for spending this token
        address operator;
        // the ID of the pool with which this token is connected
        uint80 poolId;
        // the tick range of the position
        int24 tickLower;
        int24 tickUpper;
        // the liquidity of the position
        uint128 liquidity;
        // how many uncollected tokens are owed to the position, as of the last computation
        uint128 tokensOwed0;
        uint128 tokensOwed1;

        uint128 feeOwed0;
        uint128 feeOwed1;


        uint256[] priceMap;
        uint256[] timeMap;

    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct NftDeCache{
        uint256 entryTimeSlot;
        uint256 curTimeSlot;

        uint256 curPriceSlot;
        uint256 entryPriceSlot;
        uint256 a0cache;
        uint256 a1cache;
        uint128 liquidity;
        uint8 prId;
        uint16 prCa;
        uint32 pPrice;
        uint32 cPrice;
        uint32 entryTime;
        uint32 curTime;
    }

}
