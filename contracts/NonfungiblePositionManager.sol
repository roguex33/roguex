// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "./interfaces/IRoxSpotPool.sol";
import "./libraries/FixedPoint128.sol";
import "./libraries/FullMath.sol";
import "./interfaces/IRoguexFactory.sol";
import "./interfaces/IRoxPerpPool.sol";

import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/INonfungibleTokenPositionDescriptor.sol";
import "./libraries/PositionKey.sol";
import "./libraries/PoolAddress.sol";
import "./base/LiquidityManagement.sol";
import "./base/PeripheryImmutableState.sol";
import "./base/Multicall.sol";
import "./base/ERC721Permit.sol";
import "./base/PeripheryValidation.sol";
import "./base/SelfPermit.sol";
import "./base/PoolInitializer.sol";
import './interfaces/IRoxPosnPool.sol';

/// @title NFT positions
/// @notice Wraps Liquidity Positions in the ERC721 non-fungible token interface
contract NonfungiblePositionManager is
    INonfungiblePositionManager,
    Multicall,
    ERC721Permit,
    PeripheryImmutableState,
    PoolInitializer,
    LiquidityManagement,
    PeripheryValidation,
    SelfPermit
    {
    // details about the liquidity position
    struct Position {
        // the address that is approved for spending this token
        address operator;
        
        // the nonce for permits
        uint96 nonce;
        // the ID of the pool with which this token is connected
        uint80 poolId;
        // the tick range of the position
        int24 tickLower;
        int24 tickUpper;
        // the liquidity of the position
        // the fee growth of the aggregate position as of the last action on the individual position
        // uint256 feeGrowthInside0LastX128;
        // uint256 feeGrowthInside1LastX128;
        // how many uncollected tokens are owed to the position, as of the last computation
        // uint128 tokensOwed0;
        // uint128 tokensOwed1;
    }

    /// @dev IDs of pools assigned by this contract
    mapping(address => uint80) private _poolIds;

    /// @dev Pool keys by pool ID, to save on SSTOREs for position data
    mapping(uint80 => PoolAddress.PoolKey) private _poolIdToPoolKey;

    /// @dev The token ID position data
    mapping(uint256 => Position) private _positions;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint176 private _nextId = 1;
    /// @dev The ID of the next pool that is used for the first time. Skips 0
    uint80 private _nextPoolId = 1;

    /// @dev The address of the token descriptor contract, which handles generating token URIs for position tokens
    address private immutable _tokenDescriptor;

    constructor(
        address _factory,
        address _WETH9,
        address _tokenDescriptor_
    )
        ERC721Permit("RogueX Positions NFT", "RgPOS", "1")
        PeripheryImmutableState(_factory, _WETH9)
    {
        _tokenDescriptor = _tokenDescriptor_;
    }


    /// @inheritdoc INonfungiblePositionManager
    function positions(uint256 tokenId)
        external
        view
        override
        returns (PositionDisp memory _dPos){

        address roxPos;
        bytes32 _key;
        // to avoid stack too deep
        {
            Position memory position = _positions[tokenId];
            require(position.poolId != 0, "Invalid token ID");
            _dPos.nonce = position.nonce;
            _dPos.operator = position.operator;
            _dPos.tickLower = position.tickLower;
            _dPos.tickUpper = position.tickUpper;
            PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];
            IRoxSpotPool pool = IRoxSpotPool(
                IRoguexFactory(factory).getPool(
                    poolKey.token0,
                    poolKey.token1,
                    poolKey.fee
                )
            );
            roxPos = pool.roxPosnPool();
            _dPos.token0 = poolKey.token0;
            _dPos.token1 = poolKey.token1;
            _dPos.fee = poolKey.fee;
            _key = PositionKey.compute(
                ownerOf(tokenId),
                position.tickLower,
                position.tickUpper
            );
        }

        (_dPos.liquidity,
            _dPos.spotFeeOwed0,
            _dPos.spotFeeOwed1,
            _dPos.perpFeeOwed0,
            _dPos.perpFeeOwed1,
            _dPos.tokenOwe0,
            _dPos.tokenOwe1) = IRoxPosnPool(roxPos).positions(_key);
    }

    /// @dev Caches a pool key
    function cachePoolKey(
        address pool,
        PoolAddress.PoolKey memory poolKey
    ) private returns (uint80 poolId) {
        poolId = _poolIds[pool];
        if (poolId == 0) {
            _poolIds[pool] = (poolId = _nextPoolId++);
            _poolIdToPoolKey[poolId] = poolKey;
        }
    }

    struct MintCache {
        bytes32 positionKey;
        uint80 poolId;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
    }

    /// @inheritdoc INonfungiblePositionManager
    function mint(
        MintParams calldata params
    )
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        address account = msg.sender;

        MintCache memory mCache;
        IRoxSpotPool pool;
        (liquidity, amount0, amount1, pool) = addLiquidity(
            AddLiquidityParams({
                token0: params.token0,
                token1: params.token1,
                fee: params.fee,
                recipient: account,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min
            })
        );

        _mint(params.recipient, (tokenId = _nextId++));
        // idempotent set
        mCache.poolId = cachePoolKey(
            address(pool),
            PoolAddress.PoolKey({
                token0: params.token0,
                token1: params.token1,
                fee: params.fee
            })
        );

        _positions[tokenId] = Position({
            operator: address(0),
            nonce: 0,
            poolId: mCache.poolId,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper
        });

        emit IncreaseLiquidity(tokenId, liquidity, amount0, amount1);
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not approved");
        _;
    }

    function tokenURI(
        uint256 tokenId
    )
        public
        view
        virtual
        override(ERC721, IERC721Metadata)
        returns (string memory)
    {
        require(_exists(tokenId));
        return
            INonfungibleTokenPositionDescriptor(_tokenDescriptor).tokenURI(
                this,
                tokenId
            );
    }

    // save bytecode by removing implementation of unused method
    function baseURI() public pure override returns (string memory) {}

    /// @inheritdoc INonfungiblePositionManager
    function increaseLiquidity(
        IncreaseLiquidityParams calldata params
    )
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        address account = msg.sender;
        Position storage position = _positions[params.tokenId];

        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];

        IRoxSpotPool pool;
        (liquidity, amount0, amount1, pool) = addLiquidity(
            AddLiquidityParams({
                token0: poolKey.token0,
                token1: poolKey.token1,
                fee: poolKey.fee,
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                recipient: account
            })
        );        
        emit IncreaseLiquidity(params.tokenId, liquidity, amount0, amount1);
    }

    /// @inheritdoc INonfungiblePositionManager
    function decreaseLiquidity(
        DecreaseLiquidityParams calldata params
    )
        external
        payable
        override
        isAuthorizedForToken(params.tokenId)
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        Position memory position = _positions[params.tokenId];

        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];
        // IRoxSpotPool pool = IRoxSpotPool(PoolAddress.computeAddress(factory, poolKey));
        IRoxSpotPool pool = IRoxSpotPool(
            IRoguexFactory(factory).getPool(
                poolKey.token0,
                poolKey.token1,
                poolKey.fee
            )
        );

        (amount0, amount1) = pool.burnN(
            msg.sender,
            position.tickLower,
            position.tickUpper,
            params.liquidity
        );

        require(
            amount0 >= params.amount0Min && amount1 >= params.amount1Min,
            "Price slippage check"
        );
    
        //sWrite
        _positions[params.tokenId] = position;
        emit DecreaseLiquidity(
            params.tokenId,
            params.liquidity,
            amount0,
            amount1
        );
    }

    /// @inheritdoc INonfungiblePositionManager
    function collect(
        CollectParams calldata params
    )
        external
        payable
        override
        isAuthorizedForToken(params.tokenId)
        returns (uint256 amount0, uint256 amount1)
    {
        require(params.amount0Max > 0 || params.amount1Max > 0);
        // allow collecting to the nft position manager address with address 0
        address recipient = params.recipient == address(0)
            ? address(this)
            : params.recipient;

        Position storage position = _positions[params.tokenId];

        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];

        // IRoxSpotPool pool = IRoxSpotPool(
        //     PoolAddress.computeAddress(factory, poolKey)
        // );
        IRoxSpotPool pool = IRoxSpotPool(
            IRoguexFactory(factory).getPool(
                poolKey.token0,
                poolKey.token1,
                poolKey.fee
            )
        );

        pool.burnN(msg.sender, position.tickLower, position.tickUpper, 0);
        // the actual amounts collected are returned
        (amount0, amount1) = pool.collectN(
            msg.sender,
            position.tickLower,
            position.tickUpper,
            params.amount0Max,
            params.amount1Max
        );


        emit Collect(params.tokenId, recipient, amount0, amount1);
    }

    /// @inheritdoc INonfungiblePositionManager
    function burn(
        uint256 tokenId
    ) external payable override isAuthorizedForToken(tokenId) {
        Position memory position = _positions[tokenId];
        require(position.poolId != 0, "Invalid token ID");
        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];

        IRoxSpotPool pool = IRoxSpotPool(
            IRoguexFactory(factory).getPool(
                poolKey.token0,
                poolKey.token1,
                poolKey.fee
            )
        );
        bytes32 _key = PositionKey.compute(
                        ownerOf(tokenId),
                        position.tickLower,
                        position.tickUpper
                    );

        (uint128 liquidity,
            uint128 spotFeeOwed0,
            uint128 spotFeeOwed1,
            uint128 perpFeeOwed0,
            uint128 perpFeeOwed1,
            uint128 tokensOwed0,
            uint128 tokensOwed1) = IRoxPosnPool(pool.roxPosnPool()).positions(_key);

        require(
            liquidity + spotFeeOwed0 + spotFeeOwed1 + perpFeeOwed0 == 0 &&
            perpFeeOwed1 + tokensOwed0 + tokensOwed1 == 0,
            "Not cleared"
        );
        delete _positions[tokenId];
        _burn(tokenId);
    }

    function _getAndIncrementNonce(
        uint256 tokenId
    ) internal override returns (uint256) {
        return uint256(_positions[tokenId].nonce++);
    }

    // /// @inheritdoc IERC721
    // function getApproved(uint256 tokenId) public view override(ERC721, IERC721) returns (address) {
    //     require(_exists(tokenId), 'ERC721: approved query for nonexistent token');

    //     return _positions[tokenId].operator;
    // }

    /// @dev Overrides _approve to use the operator in the position, which is packed with the position permit nonce
    // function _approve(address to, uint256 tokenId) internal override(ERC721) {
    //     _positions[tokenId].operator = to;
    //     emit Approval(ownerOf(tokenId), to, tokenId);
    // }
}