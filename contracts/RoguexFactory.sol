// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import "./interfaces/IRoguexFactory.sol";
import "./interfaces/IRoxSpotPool.sol";
import "./interfaces/IRoxSpotPoolDeployer.sol";
import "./interfaces/IRoxPerpPoolDeployer.sol";
import './interfaces/IRoxPosnPoolDeployer.sol';

import "./NoDelegateCall.sol";

// import './RoxSpotPool.sol';

interface IHypervisorFactory {
    function createHypervisor(
        address tokenA,
        address tokenB,
        uint24 fee,
        string memory name,
        string memory symbol
    ) external returns (address hypervisor);
}

/// @title Canonical Spot factory
/// @notice Deploys Spot pools and manages ownership and control over pool protocol fees
contract RoguexFactory is IRoguexFactory, NoDelegateCall {
    /// @inheritdoc IRoguexFactory
    address public override owner;
    address public override spotPoolDeployer;
    address public override hypervisorFactory;
    address public override perpPoolDeployer;
    address public override posnPoolDeployer;
    address public override utils;
    address public override weth;


    /// @inheritdoc IRoguexFactory
    mapping(uint24 => int24) public override feeAmountTickSpacing;
    /// @inheritdoc IRoguexFactory
    mapping(address => mapping(address => mapping(uint24 => address)))
        public
        override getPool;
    mapping(address => mapping(address => mapping(uint24 => address)))
        public
        override getTradePool;

    mapping(address => mapping(address => mapping(uint24 => address)))
        public
        override getPositionPool;

    mapping(address => bool) public override approvedNftRouters;
    mapping(address => bool) public override approvedPerpRouters;
    mapping(address => bool) public override approvedSpotRouters;

    mapping(address => bool) public override approvedPerpPool;
    mapping(address => bool) public override approvedSpotPool;



    uint256 public override spotThres = 800; // Default 80%, spot will be paused when perpResv / Liq.Total > spotThres 
    uint256 public override liqdThres = 800; // Default 80%, decrease liq. will be paused when perpResv / Liq.Total > liqdThres 
    uint256 public override perpThres = 500; // Default 50%, open position be paused when perpResv / Liq.Total > perpThres
    uint256 public override setlThres = 700; // Default 70%,  when perpResv / Liq.Total > perpThres


    modifier onlyOwner() {
        require(msg.sender == owner, "OW");
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnerChanged(address(0), msg.sender);

        feeAmountTickSpacing[500] = 600; //10;
        emit FeeAmountEnabled(500, 600);
        feeAmountTickSpacing[3000] = 600; //60;
        emit FeeAmountEnabled(3000, 600);
        feeAmountTickSpacing[10000] = 600; //200;
        emit FeeAmountEnabled(10000, 600);
    }

    function setSpotThres(uint256 _spotThres) external onlyOwner{
        require(_spotThres <= 1000);
        spotThres = _spotThres;
    }

    function setLiqdThres(uint256 _liqdThres) external onlyOwner{
        require(_liqdThres <= 1000);
        liqdThres = _liqdThres;
    }

    function setPerpThres(uint256 _perpThres) external onlyOwner{
        require(_perpThres <= 1000);
        perpThres = _perpThres;
    }


    function setPerpRouter(address _router, bool _status) external onlyOwner {
        approvedPerpRouters[_router] = _status;
    }
    function setNftRouter(address _router, bool _status) external onlyOwner{
        approvedNftRouters[_router] = _status;
    }
    function setSpotRouter(address _router, bool _status) external onlyOwner{
        approvedSpotRouters[_router] = _status;
    }

    function setPoolDeployer(address _dep, address _depTrade, address _depPos) external onlyOwner{
        spotPoolDeployer = _dep;
        perpPoolDeployer = _depTrade;
        posnPoolDeployer = _depPos;
    }

    function setUtils(address _rUtils, address _weth) external onlyOwner{
        utils = _rUtils;
        weth = _weth;
    }

    function setHypervisorFactory(address _hypervisorFactory) external onlyOwner{
        hypervisorFactory = _hypervisorFactory;
    }

    /// @inheritdoc IRoguexFactory
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    )
        external
        override
        noDelegateCall
        returns (address _pool, address _tradePool, address _posPool)
    {
        require(tokenA != tokenB);
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0));
        int24 tickSpacing = feeAmountTickSpacing[fee];
        require(tickSpacing != 0);
        require(getPool[token0][token1][fee] == address(0));
        require(getTradePool[token0][token1][fee] == address(0));
        _pool = IRoxSpotPoolDeployer(spotPoolDeployer).deploy(
            address(this),
            token0,
            token1,
            fee,
            tickSpacing
        );

        _tradePool = IRoxPerpPoolDeployer(perpPoolDeployer).deploy(
            address(this),
            token0,
            token1,
            fee,
            tickSpacing,
            _pool,
            utils
        );
        approvedSpotPool[_pool] = true;
        approvedPerpPool[_tradePool] = true;
        getPool[token0][token1][fee] = _pool;
        getPool[token1][token0][fee] = _pool;

        getTradePool[token0][token1][fee] = _tradePool;
        getTradePool[token1][token0][fee] = _tradePool;

 
        _posPool = IRoxPosnPoolDeployer(posnPoolDeployer).deploy(
            address(this),
            token0,
            token1,
            fee,
            _pool,
            _tradePool
        );

        getPositionPool[token0][token1][fee] = _posPool;
        getPositionPool[token1][token0][fee] = _posPool;


        if (hypervisorFactory != address(0)) {
            IHypervisorFactory(hypervisorFactory).createHypervisor(
                token0,
                token1,
                fee,
                "Lp",
                "Lp"
            );
        }
        emit PoolCreated(token0, token1, fee, tickSpacing, _pool, _tradePool);
    }

    /// @inheritdoc IRoguexFactory
    function setOwner(address _owner) external override {
        require(msg.sender == owner);
        emit OwnerChanged(owner, _owner);
        owner = _owner;
    }

    /// @inheritdoc IRoguexFactory
    function enableFeeAmount(uint24 fee, int24 tickSpacing) public override {
        require(msg.sender == owner);
        require(fee < 1000000);
        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        require(tickSpacing > 0 && tickSpacing < 16384);
        require(feeAmountTickSpacing[fee] == 0);

        feeAmountTickSpacing[fee] = tickSpacing;
        emit FeeAmountEnabled(fee, tickSpacing);
    }

}
