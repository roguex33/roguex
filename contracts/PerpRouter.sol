// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "./interfaces/IRoxSpotPool.sol";
import "./interfaces/IERC20Minimal.sol";
import "./interfaces/IRoxPerpPool.sol";
import "./interfaces/IPerpRouter.sol";
import "./interfaces/IRoguexFactory.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/EnumerableValues.sol";

import "./libraries/LowGasSafeMath.sol";
import "./libraries/SafeCast.sol";
import "./libraries/Tick.sol";
import "./libraries/TickBitmap.sol";
import "./libraries/Position.sol";
import "./libraries/Oracle.sol";

import "./libraries/FullMath.sol";
import "./libraries/FixedPoint128.sol";
import "./libraries/TickMath.sol";
import "./libraries/LiquidityMath.sol";
import "./libraries/SqrtPriceMath.sol";
import "./libraries/SwapMath.sol";
import "./libraries/TradeData.sol";
import "./libraries/TradeMath.sol";
import "./interfaces/IRoxUtils.sol";
import "./interfaces/ISwapMining.sol";


library DispData {
    struct DispTradePosition {
        address account;
        uint160 sqrtPriceX96;
        uint8 stopLossRatio;
        uint8 takeProfitRatio;
        uint32 positionTime;
        uint32 entryFundingFee;
        bool long0;
        uint256 size;
        uint256 collateral;
        uint256 reserve;
        uint256 colToken;
        int256 realisedPnl;
        address token0;
        address token1;
        uint24 fee;
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

contract PerpRouter is IPerpRouter {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableValues for EnumerableSet.Bytes32Set;

    mapping(address => EnumerableSet.Bytes32Set) positionKeys;
    mapping(bytes32 => address) public poolRev;

    address immutable public factory;
    address public roxUtils;
    address public swapMining;
    address public perpOrderbook;

    receive() external payable {
        // require(msg.sender == weth, "Router: invalid sender");
    }

    constructor(address _factory){
        factory = _factory;
    }

    function setSwapMining(address addr) public {//TEST ONLY
        require(msg.sender == IRoguexFactory(factory).owner(), "ol");
        swapMining = addr;
    }
    function setUtils(address _roguUtils, address _perpOrderbook) external { //TEST ONLY
        require(msg.sender == IRoguexFactory(factory).owner(), "ol");
        roxUtils = _roguUtils;
        perpOrderbook = _perpOrderbook;
    }

    function increasePosition(
        address _account,
        address _perpPool,
        uint256 _tokenAmount,
        uint256 _sizeDelta,
        bool _long0,
        uint160 _sqrtPriceX96
    ) external override {
        require(_tokenAmount > 0, "zero amount in");
        if (_account == address(0))
            _account = _sender();
            
        // require(_sqrtPriceX96 <= _tPrice, "pSplitage");
        if (_sqrtPriceX96 > 0){
            uint160 _pP = IRoxUtils(roxUtils).getSqrtTwapX96(IRoxPerpPool(_perpPool).spotPool());
            require(_long0 ? _sqrtPriceX96 <= _pP : _sqrtPriceX96 >= _pP, "pSplitage");
        }

        if (_long0)
            IERC20(IRoxPerpPool(_perpPool).token0()).safeTransferFrom(
                _account,
                _perpPool,
                _tokenAmount
            );
        else {
            IERC20(IRoxPerpPool(_perpPool).token1()).safeTransferFrom(
                _account,
                _perpPool,
                _tokenAmount
            );
        }
        (bytes32 key, uint256 incDelta) = IRoxPerpPool(_perpPool).increasePosition(
            _account,
            _sizeDelta,
            _long0
        );

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
        (bool _del, bool _isLiq, uint256 decDelta, address _account) = IRoxPerpPool(_perpPool).decreasePosition(
            _key,
            0,
            0,
            _sender()
        );
        require(_isLiq, "notLiq.");
        
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
        uint160 _sqrtPriceX96
    ) external override {
        if (_account == address(0))
            _account = _sender();
        else
            require(msg.sender == _account || msg.sender == perpOrderbook);

        if (_sqrtPriceX96 > 0){
            uint160 _pP = IRoxUtils(roxUtils).getSqrtTwapX96(IRoxPerpPool(_perpPool).spotPool());
            require(_long0 ? _sqrtPriceX96 >= _pP : _sqrtPriceX96 <= _pP, "pSplitage");
        }
        bytes32 _key = TradeMath.getPositionKey(_account, _perpPool, _long0);

        (bool _del, /*bool _isLiq*/, uint256 decDelta, ) = IRoxPerpPool(_perpPool).decreasePosition(
            _key,
            _collateralDelta,
            _sizeDelta,
            _account
        );

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



    function execTakingProfitSet(address roxPerpPool, bytes32 _posKey) external {
        address feeReceipt = msg.sender;
        uint256 setlThres = IRoguexFactory(factory).setlThres();
        address spotPool = IRoxPerpPool(roxPerpPool).spotPool();
        TradeData.TradePosition memory _pos = IRoxPerpPool(roxPerpPool).getPositionByKey(_posKey);
        if (_pos.long0){
            (uint256 r0,  ) = IRoxSpotPool(spotPool).availableReserve(true, false);
            require(IRoxPerpPool(roxPerpPool).reserve0() > r0.mul(setlThres).div(1000), "NP0");
        }else{
            ( , uint256 r1) = IRoxSpotPool(spotPool).availableReserve(false, true);
            require(IRoxPerpPool(roxPerpPool).reserve1() > r1.mul(setlThres).div(1000), "NP1");
        }
        require(_pos.entryPos == IRoxPerpPool(roxPerpPool).tPid(_pos.long0), "not in pos");
        IRoxPerpPool(roxPerpPool).decreasePosition(
            _posKey,
            0,
            _pos.size,
            feeReceipt
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
