// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "./interfaces/IRoxSpotPool.sol";
import "./interfaces/IERC20Minimal.sol";
import "./interfaces/IRoxPerpPool.sol";
import "./interfaces/IPerpRouter.sol";
import "./interfaces/IRoguexFactory.sol";
import './interfaces/external/IWETH9.sol';
import "./libraries/TransferHelper.sol";
import "./libraries/EnumerableValues.sol";
import "./libraries/LowGasSafeMath.sol";
import "./libraries/TradeData.sol";
import "./libraries/TradeMath.sol";
import "./interfaces/IRoxUtils.sol";
import "./interfaces/ISwapMining.sol";
import "./base/BlastBase.sol";


library DispData {
    struct DispTradePosition {
        address account;
        uint160 sqrtPriceX96;
        uint8 stopLossRatio;
        uint8 takeProfitRatio;
        uint24 fee;
        uint32 entryFundingFee;
        bool long0;


        uint256 size;
        uint256 collateral;
        uint256 reserve;
        uint256 colToken;
        int256 realisedPnl;
        address token0;
        address token1;
        uint256 closePread;
        uint256 closeSqrtPriceX96;
        uint256 liqSqrtPriceX96;
        bool hasProfit;
        uint256 delta;
        address pool;
        address spotPool;

    }

    struct FeeData{
        uint256 open0SqrtPriceX96;
        uint256 open1SqrtPriceX96;
        uint256 close0SqrtPriceX96;
        uint256 close1SqrtPriceX96;
        uint256 executionFee;
        uint256 positionFee;
        uint256 premiumLong0perHour;
        uint256 premiumLong1perHour;
        
        uint256 reserve0;
        uint256 reserve1;

        address token0;
        address token1;
        address spotPool;

        uint256 fundingFee0;
        uint256 fundingFee1;
        uint256 liquidity0;
        uint256 liquidity1;

    }
}

contract PerpRouter is IPerpRouter, BlastBase {
    using LowGasSafeMath for uint256;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableValues for EnumerableSet.Bytes32Set;

    mapping(address => EnumerableSet.Bytes32Set) positionKeys;
    mapping(bytes32 => address) public poolRev;

    address immutable public factory;
    address public roxUtils;
    address public swapMining;
    address public perpOrderbook;
    address immutable public weth;

    receive() external payable {
        require(msg.sender == weth, "invalid sender");
    }

    constructor(address _factory, address _weth){
        factory = _factory;
        weth = _weth;
    }

    function setSwapMining(address addr) public {//TEST ONLY
        require(msg.sender == IRoguexFactory(factory).owner(), "ow");
        swapMining = addr;
    }

    function setUtils(address _roguUtils, address _perpOrderbook) external { //TEST ONLY
        require(msg.sender == IRoguexFactory(factory).owner(), "ow");
        roxUtils = _roguUtils;
        perpOrderbook = _perpOrderbook;
    }

    function increasePosition(
        address /*_account*/,
        address _perpPool,
        uint256 _tokenAmount,
        uint256 _sizeDelta,
        bool _long0,
        uint160 _sqrtPriceX96
    ) external payable{
        require(_tokenAmount > 0, "z0i");
        address _account = _sender();

        if (_long0){
            address _t0 = IRoxPerpPool(_perpPool).token0();
            if (_t0 == weth && msg.value == _tokenAmount){
                IWETH9(weth).deposit{value: _tokenAmount}(); 
                IWETH9(weth).transfer(_perpPool, _tokenAmount);
            } 
            else{
                TransferHelper.safeTransferFrom(_t0, _account, _perpPool, _tokenAmount);
            }
        }
        else {
            address _t1 = IRoxPerpPool(_perpPool).token1();
            if (_t1 == weth && msg.value == _tokenAmount){
                IWETH9(weth).deposit{value: _tokenAmount}(); 
                IWETH9(weth).transfer(_perpPool, _tokenAmount);
            } 
            else{
                TransferHelper.safeTransferFrom(_t1, _account, _perpPool, _tokenAmount);
            }
        }
        _increasePosition(_account,  _perpPool, _sizeDelta, _sqrtPriceX96, _long0);
    }

    function increasePositionOrder(
        address _account,
        address _perpPool,
        uint256 _tokenAmount,
        uint256 _sizeDelta,
        bool _long0,
        uint160 _sqrtPriceX96
    ) external override {
        require(_tokenAmount > 0, "z0i");
        require (_account != address(0), "zero acc");

        // require(msg.sender == perpOrderbook, "onlyOB"); 

        if (_long0)
            TransferHelper.safeTransferFrom(IRoxPerpPool(_perpPool).token0(), msg.sender, _perpPool, _tokenAmount);
        else {
            TransferHelper.safeTransferFrom(IRoxPerpPool(_perpPool).token1(), msg.sender, _perpPool, _tokenAmount);
        }
        _increasePosition(_account,  _perpPool, _sizeDelta, _sqrtPriceX96, _long0);
    }

    function _increasePosition(
        address _account,
        address _perpPool,
        uint256 _sizeDelta,
        uint256 _opPrice,
        bool _long0
    ) private {
        require(IRoguexFactory(factory).approvedPerpPool(_perpPool), "npp");
        (bytes32 key, uint256 incDelta, uint256 openPrice) = IRoxPerpPool(_perpPool).increasePosition(
            _account,
            _sizeDelta,
            _long0
        );

        if (_opPrice > 0){
            require(_long0 ? openPrice <= _opPrice : openPrice >= _opPrice, "esp");
        }

        if (swapMining != address(0)) {
            ISwapMining(swapMining).depositSwap(
                IRoxPerpPool(_perpPool).spotPool(),
                incDelta,
                _account
            );
        }
        if (!positionKeys[_account].contains(key)) {
            positionKeys[_account].add(key);
            poolRev[key] = _perpPool;
        }
    }



    function liquidatePosition(
        address _perpPool,
        bytes32 _key
    ) external {
        require(IRoguexFactory(factory).approvedPerpPool(_perpPool), "npp");
        (bool _del, bool _isLiq, uint256 decDelta, address _account, ) = IRoxPerpPool(_perpPool).decreasePosition(
            _key,
            0,
            0,
            _sender(),
            true
        );
        require(_isLiq, "nlq");
        
        if (swapMining != address(0)) {
            ISwapMining(swapMining).depositSwap(
                IRoxPerpPool(_perpPool).spotPool(),
                decDelta,
                _account
            );
        }
        
        if (_del && positionKeys[_account].contains(_key)) {
            positionKeys[_account].remove(_key);
        }
    }


    function decreasePosition(
        address _account,
        address _perpPool,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _long0,
        bool _toETH,
        uint160 _sqrtPriceX96
    ) external override {
        require(IRoguexFactory(factory).approvedPerpPool(_perpPool), "npp");
        if (_account == address(0))
            _account = _sender();
        else
            require(msg.sender == _account || msg.sender == perpOrderbook, "irp");


        bytes32 _key = TradeMath.getPositionKey(_account, _perpPool, _long0);

        (bool _del, /*bool _isLiq*/, uint256 decDelta, , uint256 cPrice) = IRoxPerpPool(_perpPool).decreasePosition(
            _key,
            _collateralDelta,
            _sizeDelta,
            _account,
            _toETH
        );
        if (_sqrtPriceX96 > 0){
            require(_long0 ? _sqrtPriceX96 <= cPrice : _sqrtPriceX96 >= cPrice, "esp");
        }

        if (swapMining != address(0)) {
            ISwapMining(swapMining).depositSwap(
                IRoxPerpPool(_perpPool).spotPool(),
                decDelta,
                _account
            );
        }
        
        if (_del && positionKeys[_account].contains(_key)) {
            positionKeys[_account].remove(_key);
        }
    }



    function execTakingProfitSet(address _perpPool, bytes32 _posKey) external {
        require(IRoguexFactory(factory).approvedPerpPool(_perpPool), "npp");
        address feeReceipt = msg.sender;
        address spotPool = IRoxPerpPool(_perpPool).spotPool();
        uint256 setlThres = IRoxUtils(roxUtils).setlThres(spotPool);
        TradeData.TradePosition memory _pos = IRoxPerpPool(_perpPool).getPositionByKey(_posKey);
        if (_pos.long0){
            (uint256 r0,  ) = IRoxSpotPool(spotPool).availableReserve(true, false);
            require(IRoxPerpPool(_perpPool).reserve0() > r0.mul(setlThres) / (1000), "np0");
        }else{
            ( , uint256 r1) = IRoxSpotPool(spotPool).availableReserve(false, true);
            require(IRoxPerpPool(_perpPool).reserve1() > r1.mul(setlThres) / (1000), "np1");
        }
        require(_pos.entryPos == IRoxPerpPool(_perpPool).tPid(_pos.long0), "nps");
        IRoxPerpPool(_perpPool).decreasePosition(
            _posKey,
            0,
            _pos.size,
            feeReceipt,
            true
        );
    }

    function getPositionKeys(
        address _account
    ) public view returns ( bytes32[] memory){
        bytes32[] memory keyList = positionKeys[_account].valuesAt(
            0,
            positionKeys[_account].length()
        );
        return keyList;
    }

    function _sender() private view returns (address) {
        return msg.sender;
    }

}
