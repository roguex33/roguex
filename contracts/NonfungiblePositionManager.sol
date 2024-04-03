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
// import "./libraries/PositionKey.sol";
import "./libraries/PoolAddress.sol";
import "./base/LiquidityManagement.sol";
import "./base/PeripheryImmutableState.sol";
import "./base/Multicall.sol";
import "./base/ERC721Permit.sol";
import "./base/PeripheryValidation.sol";
import "./base/SelfPermit.sol";
import './interfaces/IRoxPosnPool.sol';
import "./interfaces/IRoxUtils.sol";
import "./base/BlastBase.sol";

/// @title NFT positions
/// @notice Wraps Liquidity Positions in the ERC721 non-fungible token interface
contract NonfungiblePositionManager is
    INonfungiblePositionManager,
    Multicall,
    ERC721,
    PeripheryImmutableState,
    LiquidityManagement,
    PeripheryValidation,
    SelfPermit
    {
    // details about the liquidity position
    struct Position {
        address owner;
        uint80 poolId;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @dev IDs of pools assigned by this contract
    mapping(address => uint80) private _poolIds;

    /// @dev Pool keys by pool ID, to save on SSTOREs for position data
    mapping(uint80 => PoolAddress.PoolKey) private _poolIdToPoolKey;

    /// @dev The token ID position data
    mapping(uint256 => Position) private _positions;
    mapping(bytes32 => uint256) public keyId;
    /// @dev The ID of the next token that will be minted. Skips 0
    uint176 private _nextId = 1;
    /// @dev The ID of the next pool that is used for the first time. Skips 0
    uint80 private _nextPoolId = 1;

    /// @dev The address of the token descriptor contract, which handles generating token URIs for position tokens
    address private immutable _tokenDescriptor;

    address public immutable roxUtils;


    constructor(
        address _factory,
        address _WETH9,
        address _tokenDescriptor_,
        address _roxUtils
    )
        ERC721("RogueX Positions NFT", "RgPOS")
        PeripheryImmutableState(_factory, _WETH9)
    {
        _tokenDescriptor = _tokenDescriptor_;
        roxUtils = _roxUtils;
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
            _dPos.operator = position.owner;
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
        return _mintLiq(params);
    }

    function _mintLiq(
        MintParams calldata params
    ) private returns (
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

        bytes32 _nftkey = nftcompute(
                account,
                params.tickLower,
                params.tickUpper,
                address(pool)
            );
        require(keyId[_nftkey] < 1, "already minted.");

        _mint(account, (tokenId = _nextId++));
        keyId[_nftkey] = tokenId;
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
            owner: account,
            poolId: mCache.poolId,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper
        });

        emit IncreaseLiquidity(tokenId, liquidity, amount0, amount1);
    }



    function createAndInitializePoolAndAddLiq(
        uint160 sqrtPriceX96,
        MintParams calldata params,
        uint8 _maxLeverage,
        uint16 _spotThres,
        uint16 _perpThres,
        uint16 _setlThres,
        uint32 _fdFeePerS,
        uint32 _twapTime,
        uint8 _countFrame
    ) external payable returns (address pool) {
        require(params.token0 < params.token1);
        pool = IRoguexFactory(factory).getPool(params.token0, params.token1, params.fee);

        if (pool == address(0)) {
            (pool, , ) = IRoguexFactory(factory).createPool(
                params.token0,
                params.token1,
                params.fee,
                msg.sender
            );
            IRoxSpotPool(pool).initialize(sqrtPriceX96);
        } else {
            (uint160 sqrtPriceX96Existing, , , , , , ) = IRoxSpotPool(pool)
                .slot0();
            if (sqrtPriceX96Existing == 0) {
                IRoxSpotPool(pool).initialize(sqrtPriceX96);
            }
        }
        _mintLiq(params);

        IRoxUtils(roxUtils).modifyPoolSetting(pool, 
            _maxLeverage,
            _spotThres,
            _perpThres,
            _setlThres,
            _fdFeePerS,
            _twapTime,
            _countFrame,
            false
            );
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


    /// @inheritdoc INonfungiblePositionManager
    function increaseLiquidity(
        IncreaseLiquidityParams calldata params
    )
        external
        payable
        override
        isAuthorizedForToken(params.tokenId)
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
            "Token received check"
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
        (amount0, amount1) = pool.collect(
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

        {
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
        }

        keyId[nftcompute(
                ownerOf(tokenId),
                position.tickLower,
                position.tickUpper,
                address(pool)
            )] = 0;
        delete _positions[tokenId];
        _burn(tokenId);
    }




    function nftcompute(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        address spotPool
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper, spotPool));
    }

    function transferFrom(address, address, uint256) public pure override(ERC721, IERC721) {
        revert("ns");
    }
    function safeTransferFrom(address, address, uint256) public pure override(ERC721, IERC721) {
        revert("ns");
    }
    function safeTransferFrom(address, address, uint256, bytes memory) public pure override(ERC721, IERC721) {
        revert("ns");
    }
    function approve(address, uint256) public pure override(ERC721, IERC721) {
        revert("ns");
    }
    function setApprovalForAll(address, bool) public pure override(ERC721, IERC721) {
        revert("ns");
    }
    // save bytecode by removing implementation of unused method
    function baseURI() public pure override returns (string memory) {}

}