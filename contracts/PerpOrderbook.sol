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
import "./interfaces/IRoxUtils.sol";
import "./interfaces/ISwapMining.sol";
import "./interfaces/IRoxUtils.sol";
import "./interfaces/IPerpRouter.sol";


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

import "hardhat/console.sol";

interface IWETH is IERC20 {
    /// @notice Deposit ether to get wrapped ether
    function deposit() external payable;

    /// @notice Withdraw wrapped ether to get ether
    function withdraw(uint256) external;
}


library OrderData {
    struct IncreaseOrder {
        address account;
        address perpPool;
        uint128 collateralIn;
        uint128 executionFee;
        uint256 sizeDelta;
        bool long0;
        bool triggerAboveThreshold;
        bool shouldWarp;
        uint160 triggerPrice;
    }

    struct DecreaseOrder {
        address account;
        address perpPool;
        uint256 sizeDelta;

        uint128 collateralDelta;
        uint128 executionFee;
        bool long0;
        bool triggerAboveThreshold;
        bool shouldWarp;
        uint160 triggerPrice;
    }
}




contract PerpOrderbook {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableValues for EnumerableSet.UintSet;


    uint256 public increaseOrdersIndex;
    uint256 public decreaseOrdersIndex;

    mapping (address => EnumerableSet.UintSet) internal increaseOrderKeysAlive;
    mapping (uint256 => OrderData.IncreaseOrder) internal increaseOrders;

    mapping (address => EnumerableSet.UintSet) internal decreaseOrderKeysAlive;
    mapping (uint256 => OrderData.DecreaseOrder) internal decreaseOrders;

    address public weth;
    address public factory;
    address public roxUtils;
    address public tradeRouter;

    event CreateIncreaseOrder(OrderData.IncreaseOrder);
    event UpdateIncreaseOrder(OrderData.IncreaseOrder);
    event CancelIncreaseOrder(OrderData.IncreaseOrder);
    event ExecuteDecreaseOrder(OrderData.DecreaseOrder, uint256 executePrice);
    event CreateDecreaseOrder(OrderData.DecreaseOrder);
    event UpdateDecreaseOrder(OrderData.DecreaseOrder);
    event CancelDecreaseOrder(OrderData.DecreaseOrder);
    event ExecuteIncreaseOrder(OrderData.IncreaseOrder, uint256 executePrice);


    receive() external payable {
        require(msg.sender == weth, "IS");
    }

    constructor(address _weth, address _factory) {
        weth = _weth;
        factory = _factory;
    }

    function setUtils(address _roguUtils, address _tradeRouter) external { //TEST ONLY
        // require(msg.sender == factory, "ol");
        roxUtils = _roguUtils;
        tradeRouter = _tradeRouter;
    }


    function getIncreaseOrder(uint256 _id) public view returns (OrderData.IncreaseOrder memory){
        return increaseOrders[_id];
    }
    function getPendingIncreaseOrdersKeys(address _account) public view returns (uint256[] memory){
        return increaseOrderKeysAlive[_account].valuesAt(0, increaseOrderKeysAlive[_account].length());
    }

    function getPendingIncreaseOrders(address _account) public view returns (OrderData.IncreaseOrder[] memory){
        uint256[] memory keys = getPendingIncreaseOrdersKeys(_account);
        OrderData.IncreaseOrder[] memory orders = new OrderData.IncreaseOrder[](keys.length);
        for(uint64 i = 0; i < orders.length; i++){
            orders[i] = increaseOrders[keys[i]];
        }
        return orders;
    }
    function pendingIncreaseOrdersNum(address _account) public view returns (uint256){
        return increaseOrderKeysAlive[_account].length();
    }
    function isIncreaseOrderKeyAlive(uint256 _increaseKey) public view returns (bool){
        return increaseOrderKeysAlive[address(0)].contains(_increaseKey);
    }

    function getDecreaseOrderByKey(uint256 _decreaseKey) public view returns (OrderData.DecreaseOrder memory){
        return decreaseOrders[_decreaseKey];
    }
    function getPendingDecreaseOrdersKeys(address _account) public view returns (uint256[] memory){
        return decreaseOrderKeysAlive[_account].valuesAt(0, decreaseOrderKeysAlive[_account].length());
    }    
    function getPendingDecreaseOrders(address _account) public view returns (OrderData.DecreaseOrder[] memory){
        uint256[] memory keys = getPendingDecreaseOrdersKeys(_account);
        OrderData.DecreaseOrder[] memory orders = new OrderData.DecreaseOrder[](keys.length);
        for(uint64 i = 0; i < orders.length; i++){
            orders[i] = decreaseOrders[keys[i]];
        }
        return orders;
    }
    function pendingDecreaseOrdersNum(address _account) public view returns (uint256){
        return decreaseOrderKeysAlive[_account].length();
    }
    function isDecreaseOrderKeyAlive(uint256 _decreaseKey) public view returns (bool){
        return decreaseOrderKeysAlive[address(0)].contains(_decreaseKey);
    }
    function getPendingOrders(address _account) public view returns (OrderData.IncreaseOrder[] memory, OrderData.DecreaseOrder[] memory){
        return (getPendingIncreaseOrders(_account), getPendingDecreaseOrders(_account));
    }




    //------ Increase Orders
    function createIncreaseOrder(
        address _perpPool,
        uint128 _tokenAmount,
        uint128 _exeFee,
        uint256 _sizeDelta,
        uint160 _triggerPriceSqrtX96,
        bool _long0,
        bool _triggerAboveThreshold,
        bool _shouldWarp
        ) external payable {
        require(_tokenAmount > _exeFee, "Fee>Col");
        //TODO:
        // valid perpPool
        address _account = msg.sender;
        address _colToken = _long0 ? IRoxPerpPool(_perpPool).token0() : IRoxPerpPool(_perpPool).token1();
        if (_shouldWarp) {
            require(_tokenAmount <= msg.value);
            _transferInETH();
        } else {
            IERC20(_colToken).safeTransferFrom(_account, address(this), _tokenAmount);
        }

        uint256 _orderIndex = (increaseOrdersIndex+=1);
        // bytes32 _key = getRequestKey(_account, _orderIndex, "increase");
        increaseOrders[_orderIndex] = OrderData.IncreaseOrder({
            account : _account,
            perpPool : _perpPool,
            collateralIn : _tokenAmount - _exeFee,
            sizeDelta : _sizeDelta,
            executionFee : _exeFee,
            long0 : _long0,
            triggerAboveThreshold : _triggerAboveThreshold,
            shouldWarp : _shouldWarp,
            triggerPrice : _triggerPriceSqrtX96
        });
        increaseOrderKeysAlive[address(0)].add(_orderIndex);
        increaseOrderKeysAlive[_account].add(_orderIndex);
        // emit CreateIncreaseOrder(order);
    }

    function executeIncreaseOrder(uint256 _key, address _feeReceipt) external {
        OrderData.IncreaseOrder memory order = increaseOrders[_key];
        require(isIncreaseOrderKeyAlive(_key) && order.account != address(0), "no order");

        // increase long should use max price
        // increase short should use min price
        (uint256 currentPrice, bool isValid) = validatePositionOrderPrice(
            order.perpPool,
            order.triggerAboveThreshold,
            order.triggerPrice
        );
        require(isValid, "Invalid Trig.Price");

        address _colToken = order.long0 ? IRoxPerpPool(order.perpPool).token0() : IRoxPerpPool(order.perpPool).token1();

        IERC20(_colToken).approve(tradeRouter, order.collateralIn);

        IPerpRouter(tradeRouter).increasePosition(
            order.account,
            order.perpPool,
            order.collateralIn,
            order.sizeDelta,
            order.long0,
            0);
        IERC20(_colToken).safeTransfer(_feeReceipt, order.executionFee);

        emit ExecuteIncreaseOrder(order, currentPrice);
        increaseOrderKeysAlive[order.account].remove(_key);       
        increaseOrderKeysAlive[address(0)].remove(_key);
        delete increaseOrders[_key];
        // delete increaseOrderKeys[msg.sender][order.index];
    }

    function cancelIncreaseOrder(uint256 _orderIndex) public {
        OrderData.IncreaseOrder memory order = increaseOrders[_orderIndex];
        require(isIncreaseOrderKeyAlive(_orderIndex), "no-order");
        require(order.account == msg.sender, "OnlyOwner");

        address _colToken = order.long0 ? IRoxPerpPool(order.perpPool).token0() : IRoxPerpPool(order.perpPool).token1();

        uint256 tokenBack = order.collateralIn + order.executionFee;
        if (order.shouldWarp) {
            _transferOutETH(tokenBack, payable(msg.sender)); 
        } else {
            IERC20(_colToken).safeTransfer(msg.sender, tokenBack);
        }

        emit CancelIncreaseOrder(order);
        increaseOrderKeysAlive[order.account].remove(_orderIndex);       
        increaseOrderKeysAlive[address(0)].remove(_orderIndex);
        delete increaseOrders[_orderIndex];
    }


    function updateIncreaseOrder(
        uint256 _key, 
        int256 _sizeDelta, 
        int256 _colDelta,
        int256 _feeDelta,
        uint160 _triggerPrice, 
        bool _triggerAboveThreshold) public payable {

        require(isIncreaseOrderKeyAlive(_key), "no key");
        OrderData.IncreaseOrder memory order = increaseOrders[_key];
        require(msg.sender == order.account, "Forbiden");
        require(order.account != address(0), "no-order");

        if (_sizeDelta > 0){
            order.sizeDelta += uint256(_sizeDelta);
        }else if (_sizeDelta < 0){
            require(order.sizeDelta > uint256(-_sizeDelta), "xS");
            order.sizeDelta -= uint256(-_sizeDelta);
        }

        if (_colDelta > 0){
            order.collateralIn += uint128(_colDelta);
        }else if (_colDelta < 0){
            require(order.collateralIn > uint256(-_colDelta), "xS");
            order.collateralIn -= uint128(-_colDelta);
        }

        if (_feeDelta > 0){
            order.executionFee += uint128(_feeDelta);
        }else if (_feeDelta < 0){
            require(order.executionFee >= uint128(-_feeDelta), "xS");
            order.executionFee -= uint128(-_feeDelta);
        }

        order.triggerPrice = _triggerPrice;
        order.triggerAboveThreshold = _triggerAboveThreshold;

        address _colToken = order.long0 ? IRoxPerpPool(order.perpPool).token0() : IRoxPerpPool(order.perpPool).token1();
        int256 _inDelta = _colDelta + _feeDelta;
        if (_inDelta > 0){
            if (order.shouldWarp) {
                require(uint256(_inDelta) == msg.value);
                _transferInETH();
            } else {
                IERC20(_colToken).safeTransferFrom(order.account, address(this), uint256(_inDelta));
            }
        }
        else if (_inDelta < 0){
            IERC20(_colToken).safeTransfer(order.account, uint256(-_inDelta));
        }
        
        // sWrite to update
        increaseOrders[_key] = order;
        emit UpdateIncreaseOrder(order);
    }










    //------ Decrease Orders
    function createDecreaseOrder(
        address _perpPool,
        uint128 _exeFee,
        uint128 _colDelta,
        uint256 _sizeDelta,
        uint160 _triggerPriceSqrtX96,
        bool _long0,
        bool _triggerAboveThreshold,
        bool _shouldWarp
        ) external payable {
        //TODO:
        // valid perpPool
        address _account = msg.sender;
        address _colToken = _long0 ? IRoxPerpPool(_perpPool).token0() : IRoxPerpPool(_perpPool).token1();
        
        if (_shouldWarp) {
            require(_exeFee == msg.value);
            _transferInETH();
        } else {
            IERC20(_colToken).safeTransferFrom(_account, address(this), _exeFee);
        }

        uint256 _orderIndex = (decreaseOrdersIndex++);

        decreaseOrders[_orderIndex] = OrderData.DecreaseOrder({
            account : _account,
            perpPool : _perpPool,
            sizeDelta : _sizeDelta,
            collateralDelta : _colDelta,
            executionFee : _exeFee,
            long0 : _long0,
            triggerAboveThreshold : _triggerAboveThreshold,
            shouldWarp : _shouldWarp,
            triggerPrice : _triggerPriceSqrtX96
        });
        decreaseOrderKeysAlive[address(0)].add(_orderIndex);
        decreaseOrderKeysAlive[_account].add(_orderIndex);
        emit CreateDecreaseOrder(decreaseOrders[_orderIndex]);
    }


    function cancelDecreaseOrder(uint256 _orderIndex) public {
        OrderData.DecreaseOrder memory order = decreaseOrders[_orderIndex];
        require(isDecreaseOrderKeyAlive(_orderIndex), "no-order");
        require(order.account == msg.sender, "OnlyOwner");

        address _colToken = order.long0 ? IRoxPerpPool(order.perpPool).token0() : IRoxPerpPool(order.perpPool).token1();

        uint256 tokenBack = order.executionFee;
        if (order.shouldWarp) {
            _transferOutETH(tokenBack, payable(msg.sender)); 
        } else {
            IERC20(_colToken).safeTransfer(msg.sender, tokenBack);
        }

        emit CancelDecreaseOrder(order);
        decreaseOrderKeysAlive[order.account].remove(_orderIndex);       
        decreaseOrderKeysAlive[address(0)].remove(_orderIndex);
        delete decreaseOrders[_orderIndex];
    }



    function executeDecreaseOrder(uint256 _key, address _feeReceipt) external {
        OrderData.DecreaseOrder memory order = decreaseOrders[_key];
        require(isDecreaseOrderKeyAlive(_key) && order.account != address(0), "no order");

        (uint256 currentPrice, bool isValid) = validatePositionOrderPrice(
            order.perpPool,
            order.triggerAboveThreshold,
            order.triggerPrice
        );
        require(isValid, "Invalid Trig.Price");

        address _colToken = order.long0 ? IRoxPerpPool(order.perpPool).token0() : IRoxPerpPool(order.perpPool).token1();

        IPerpRouter(tradeRouter).decreasePosition(
            order.account,
            order.perpPool,
            order.collateralDelta,
            order.sizeDelta,
            order.long0,
            0);

        IERC20(_colToken).safeTransfer(_feeReceipt, order.executionFee);

        emit ExecuteDecreaseOrder(order, currentPrice);
        decreaseOrderKeysAlive[order.account].remove(_key);       
        decreaseOrderKeysAlive[address(0)].remove(_key);
        delete decreaseOrders[_key];
    }

    function updateDecreaseOrder(
        uint256 _key, 
        int256 _sizeDelta, 
        int256 _colDelta,
        int256 _feeDelta,
        uint160 _triggerPrice, 
        bool _triggerAboveThreshold) public payable {

        require(isDecreaseOrderKeyAlive(_key), "no key");
        OrderData.DecreaseOrder memory order = decreaseOrders[_key];
        require(msg.sender == order.account, "Forbiden");
        require(order.account != address(0), "no-order");

        if (_sizeDelta > 0){
            order.sizeDelta += uint256(_sizeDelta);
        }else if (_sizeDelta < 0){
            require(order.sizeDelta > uint256(-_sizeDelta), "xS");
            order.sizeDelta -= uint256(-_sizeDelta);
        }

        if (_colDelta > 0){
            order.collateralDelta += uint128(_colDelta);
        }else if (_colDelta < 0){
            require(order.collateralDelta > uint256(-_colDelta), "xD");
            order.collateralDelta -= uint128(-_colDelta);
        }

        if (_feeDelta > 0){
            order.executionFee += uint128(_feeDelta);
        }else if (_feeDelta < 0){
            require(order.executionFee >= uint128(-_feeDelta), "xF");
            order.executionFee -= uint128(-_feeDelta);
        }

        order.triggerPrice = _triggerPrice;
        order.triggerAboveThreshold = _triggerAboveThreshold;

        address _colToken = order.long0 ? IRoxPerpPool(order.perpPool).token0() : IRoxPerpPool(order.perpPool).token1();
        int256 _inDelta = _feeDelta;
        if (_inDelta > 0){
            if (order.shouldWarp) {
                require(uint256(_inDelta) == msg.value);
                _transferInETH();
            } else {
                IERC20(_colToken).safeTransferFrom(order.account, address(this), uint256(_inDelta));
            }
        }
        else if (_inDelta < 0){
            IERC20(_colToken).safeTransfer(order.account, uint256(-_inDelta));
        }

        // sWrite to update
        decreaseOrders[_key] = order;
        emit UpdateDecreaseOrder(order);
    }


    //--------
    function _transferInETH() private {
        if (msg.value != 0) {
            IWETH(weth).deposit{value: msg.value}();
        }
    }
    function _transferOutETH(uint256 _amountOut, address payable _receiver) private {
        IWETH(weth).withdraw(_amountOut);
        _receiver.sendValue(_amountOut);
    }


    function validatePositionOrderPrice(
        address _perpPool,
        bool _triggerAboveThreshold,
        uint256 _triggerPrice
    ) public view returns (uint256, bool) {
        uint256 currentPrice = IRoxUtils(roxUtils).getSqrtTwapX96(IRoxPerpPool(_perpPool).spotPool());
        bool isPriceValid = _triggerAboveThreshold ? currentPrice > _triggerPrice : currentPrice < _triggerPrice;
        return (currentPrice, isPriceValid);
    }


    


}
