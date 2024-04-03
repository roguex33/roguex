// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import "./libraries/PoolAddress.sol";
import "./interfaces/IRoguexFactory.sol";
import "./interfaces/IRoxSpotPool.sol";
import "./interfaces/IRoxSpotPoolDeployer.sol";
import "./interfaces/IRoxPerpPoolDeployer.sol";
import './interfaces/IRoxPosnPoolDeployer.sol';
import "./NoDelegateCall.sol";
import "./base/BlastBase.sol";

// import './RoxSpotPool.sol';

interface IHypervisorFactory {
    function createHypervisor(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external returns (address hypervisor);
}

/// @title Canonical Spot factory
/// @notice Deploys Spot pools and manages ownership and control over pool protocol fees
contract RoguexFactory is IRoguexFactory, NoDelegateCall, BlastBase {
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

    mapping(address => address) public spotCreator;
    mapping(address => address) public override spotHyper;
    mapping(address => address) private _spotOwner;



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


    function spotOwner(address _spotPool) public override view returns (address){
        address _ow =  _spotOwner[_spotPool];
        return _ow == address(0) ? owner : _ow;
    }

    function transferOwner(address _pool, address _new) external{
        require(spotOwner(_pool) == msg.sender, "not creator");
        _spotOwner[_pool] = _new;
    }

    function transferCreator(address _pool, address _new) external{
        require(spotCreator[_pool] != address(0), "empty Pool");
        require(spotCreator[_pool] == msg.sender, "not creator");
        spotCreator[_pool] = _new;
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
        uint24 fee,
        address poolOwner
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
        // int24 tickSpacing = feeAmountTickSpacing[fee];
        // require(tickSpacing != 0);
        require(getPool[token0][token1][fee] == address(0));
        require(getTradePool[token0][token1][fee] == address(0));


        PoolAddress.PoolKey memory _pKey = PoolAddress.PoolKey({
                token0: token0,
                token1: token1,
                fee: fee
            });
        
        // address _calSpot =  PoolAddress.computeAddress(spotPoolDeployer, _pKey);
        address _calPerp =  PoolAddress.perpAddress(perpPoolDeployer, _pKey);
        address _calPosn =  PoolAddress.posnAddress(posnPoolDeployer, _pKey);


        _pool = IRoxSpotPoolDeployer(spotPoolDeployer).deploy(
            address(this),
            token0,
            token1,
            fee,
            _calPerp,
            _calPosn,
            utils
        );

        _tradePool = IRoxPerpPoolDeployer(perpPoolDeployer).deploy(
            address(this),
            token0,
            token1,
            fee,
            _pool,
            _calPosn
        );
        require(_calPerp == _tradePool, "PerpAdd");
        approvedSpotPool[_pool] = true;
        approvedPerpPool[_tradePool] = true;
        getPool[token0][token1][fee] = _pool;
        getPool[token1][token0][fee] = _pool;
        spotCreator[_pool] = msg.sender;

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
        require(_calPosn == _posPool, "PosnAdd");

        getPositionPool[token0][token1][fee] = _posPool;
        getPositionPool[token1][token0][fee] = _posPool;


        if (hypervisorFactory != address(0)) {
            spotHyper[_pool] = IHypervisorFactory(hypervisorFactory).createHypervisor(
                token0,
                token1,
                fee
            );
        }
        emit PoolCreated(token0, token1, fee, 600, _pool, _tradePool);

        _spotOwner[_pool] = poolOwner;
        spotCreator[_pool] = poolOwner;
    }

    /// @inheritdoc IRoguexFactory
    function transferOwnership(address _owner) external override {
        require(msg.sender == owner);
        emit OwnerChanged(owner, _owner);
        owner = _owner;
    }


}
