// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "./interfaces/IRoxPerpPool.sol";
import "./interfaces/IRoxUtils.sol";
import "./interfaces/IPerpRouter.sol";
import "./interfaces/IRoguexFactory.sol";
import "./libraries/EnumerableValues.sol";
import "./libraries/LowGasSafeMath.sol";
import "./libraries/TransferHelper.sol";
import './interfaces/external/IWETH9.sol';
import "./base/BlastBase.sol";


library OrderData {
    struct IncreaseOrder {
        address spotpool;
        address account;
        address perpPool;
        address token0;
        address token1;
        uint256 key;
        uint128 collateralIn;
        uint128 executionFee;
        uint256 sizeDelta;
        bool long0;
        bool triggerAboveThreshold;
        bool shouldWarp;
        uint160 triggerPrice;
    }

    struct DecreaseOrder {
        address spotpool;
        address account;
        address perpPool;
        address token0;
        address token1;
        uint256 key;
        uint256 sizeDelta;
        uint128 collateralDelta;
        uint128 executionFee;
        bool long0;
        bool triggerAboveThreshold;
        bool shouldWarp;
        uint160 triggerPrice;
    }
}

contract PerpOrderbook is BlastBase, ReentrancyGuard {
    using LowGasSafeMath for uint256;
    // using Address for address payable;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableValues for EnumerableSet.UintSet;

    uint256 public increaseOrdersIndex;
    uint256 public decreaseOrdersIndex;

    mapping(address => EnumerableSet.UintSet) internal increaseOrderKeysAlive;
    mapping(uint256 => OrderData.IncreaseOrder) internal increaseOrders;

    mapping(address => EnumerableSet.UintSet) internal decreaseOrderKeysAlive;
    mapping(uint256 => OrderData.DecreaseOrder) internal decreaseOrders;

    address public weth;
    address public factory;
    address public roxUtils;
    address public perpRouter;

    event CreateIncreaseOrder(OrderData.IncreaseOrder);
    event UpdateIncreaseOrder(OrderData.IncreaseOrder);
    event CancelIncreaseOrder(OrderData.IncreaseOrder);
    event ExecuteDecreaseOrder(OrderData.DecreaseOrder, uint256 executePrice);
    event CreateDecreaseOrder(OrderData.DecreaseOrder);
    event UpdateDecreaseOrder(OrderData.DecreaseOrder);
    event CancelDecreaseOrder(OrderData.DecreaseOrder);
    event ExecuteIncreaseOrder(OrderData.IncreaseOrder, uint256 executePrice);

    receive() external payable {
        require(msg.sender == weth, "weth");
    }

    constructor(address _weth, address _factory) {
        weth = _weth;
        factory = _factory;
    }

    function setUtils(address _roguUtils, address _tradeRouter) external {
        require(msg.sender == IRoguexFactory(factory).owner(), "ol");
        roxUtils = _roguUtils;
        perpRouter = _tradeRouter;
    }

    function getIncreaseOrder(
        uint256 _id
    ) public view returns (OrderData.IncreaseOrder memory) {
        return increaseOrders[_id];
    }

    function getPendingIncreaseOrdersKeys(
        address _account
    ) public view returns (uint256[] memory) {
        return
            increaseOrderKeysAlive[_account].valuesAt(
                0,
                increaseOrderKeysAlive[_account].length()
            );
    }

    function getPendingIncreaseOrders(
        address _account
    ) public view returns (OrderData.IncreaseOrder[] memory) {
        uint256[] memory keys = getPendingIncreaseOrdersKeys(_account);
        OrderData.IncreaseOrder[] memory orders = new OrderData.IncreaseOrder[](
            keys.length
        );
        for (uint64 i = 0; i < orders.length; i++) {
            orders[i] = increaseOrders[keys[i]];
        }
        return orders;
    }

    function pendingIncreaseOrdersNum(
        address _account
    ) public view returns (uint256) {
        return increaseOrderKeysAlive[_account].length();
    }

    function isIncreaseOrderKeyAlive(
        uint256 _increaseKey
    ) public view returns (bool) {
        return increaseOrderKeysAlive[address(0)].contains(_increaseKey);
    }

    function getDecreaseOrderByKey(
        uint256 _decreaseKey
    ) public view returns (OrderData.DecreaseOrder memory) {
        return decreaseOrders[_decreaseKey];
    }

    function getPendingDecreaseOrdersKeys(
        address _account
    ) public view returns (uint256[] memory) {
        return
            decreaseOrderKeysAlive[_account].valuesAt(
                0,
                decreaseOrderKeysAlive[_account].length()
            );
    }

    function getPendingDecreaseOrders(
        address _account
    ) public view returns (OrderData.DecreaseOrder[] memory) {
        uint256[] memory keys = getPendingDecreaseOrdersKeys(_account);
        OrderData.DecreaseOrder[] memory orders = new OrderData.DecreaseOrder[](
            keys.length
        );
        for (uint64 i = 0; i < orders.length; i++) {
            orders[i] = decreaseOrders[keys[i]];
        }
        return orders;
    }

    function pendingDecreaseOrdersNum(
        address _account
    ) public view returns (uint256) {
        return decreaseOrderKeysAlive[_account].length();
    }

    function isDecreaseOrderKeyAlive(
        uint256 _decreaseKey
    ) public view returns (bool) {
        return decreaseOrderKeysAlive[address(0)].contains(_decreaseKey);
    }

    function getPendingOrders(
        address _account
    )
        public
        view
        returns (
            OrderData.IncreaseOrder[] memory,
            OrderData.DecreaseOrder[] memory
        )
    {
        return (
            getPendingIncreaseOrders(_account),
            getPendingDecreaseOrders(_account)
        );
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
    ) external payable nonReentrant{
        require(_tokenAmount > _exeFee, "Fee>Col");
        address _account = msg.sender;
        address token0 = IRoxPerpPool(_perpPool).token0();
        address token1 = IRoxPerpPool(_perpPool).token1();
        address _colToken = _long0 ? token0 : token1;
        if (_shouldWarp) {
            require(_tokenAmount <= msg.value);
            _transferInETH();
        } else {
            TransferHelper.safeTransferFrom(
                _colToken,
                _account,
                address(this),
                _tokenAmount);
        }

        uint256 _orderIndex = (increaseOrdersIndex += 1);
        // bytes32 _key = getRequestKey(_account, _orderIndex, "increase");
        increaseOrders[_orderIndex] = OrderData.IncreaseOrder({
            spotpool: IRoxPerpPool(_perpPool).spotPool(),
            account: _account,
            perpPool: _perpPool,
            token0: token0,
            token1: token1,
            key: _orderIndex,
            collateralIn: _tokenAmount - _exeFee,
            sizeDelta: _sizeDelta,
            executionFee: _exeFee,
            long0: _long0,
            triggerAboveThreshold: _triggerAboveThreshold,
            shouldWarp: _shouldWarp,
            triggerPrice: _triggerPriceSqrtX96
        });
        increaseOrderKeysAlive[address(0)].add(_orderIndex);
        increaseOrderKeysAlive[_account].add(_orderIndex);
        emit CreateIncreaseOrder(increaseOrders[_orderIndex]);
    }

    function executeIncreaseOrder(uint256 _key, address _feeReceipt) external nonReentrant{
        OrderData.IncreaseOrder memory order = increaseOrders[_key];
        require(
            isIncreaseOrderKeyAlive(_key) && order.account != address(0),
            "no order"
        );

        // increase long should use max price
        // increase short should use min price
        (uint256 currentPrice, bool isValid) = validatePositionOrderPrice(
            order.perpPool,
            order.triggerAboveThreshold,
            order.triggerPrice
        );
        require(isValid, "Invalid Trig.Price");

        address _colToken = order.long0
            ? IRoxPerpPool(order.perpPool).token0()
            : IRoxPerpPool(order.perpPool).token1();

        IERC20(_colToken).approve(perpRouter, order.collateralIn);

        IPerpRouter(perpRouter).increasePositionOrder(
            order.account,
            order.perpPool,
            order.collateralIn,
            order.sizeDelta,
            order.long0,
            0
        );
        TransferHelper.safeTransfer(
                _colToken,
                _feeReceipt,
                order.executionFee);

        emit ExecuteIncreaseOrder(order, currentPrice);
        increaseOrderKeysAlive[order.account].remove(_key);
        increaseOrderKeysAlive[address(0)].remove(_key);
        delete increaseOrders[_key];
        // delete increaseOrderKeys[msg.sender][order.index];
    }

    function cancelIncreaseOrder(uint256 _orderIndex) public nonReentrant{
        OrderData.IncreaseOrder memory order = increaseOrders[_orderIndex];
        require(isIncreaseOrderKeyAlive(_orderIndex), "no-order");
        require(order.account == msg.sender, "OnlyOwner");
        increaseOrderKeysAlive[order.account].remove(_orderIndex);
        increaseOrderKeysAlive[address(0)].remove(_orderIndex);

        address _colToken = order.long0
            ? IRoxPerpPool(order.perpPool).token0()
            : IRoxPerpPool(order.perpPool).token1();

        uint256 tokenBack = order.collateralIn + order.executionFee;
        if (order.shouldWarp) {
            _transferOutETH(tokenBack, payable(msg.sender));
        } else {
            // IERC20(_colToken).safeTransfer(msg.sender, tokenBack);
            TransferHelper.safeTransfer(
                _colToken,
                msg.sender,
                tokenBack);
        }

        emit CancelIncreaseOrder(order);

        delete increaseOrders[_orderIndex];
    }

    function updateIncreaseOrder(
        uint256 _key,
        int256 _sizeDelta,
        int256 _colDelta,
        int256 _feeDelta,
        uint160 _triggerPrice,
        bool _triggerAboveThreshold
    ) public payable nonReentrant{
        require(isIncreaseOrderKeyAlive(_key), "no key");
        OrderData.IncreaseOrder memory order = increaseOrders[_key];
        require(msg.sender == order.account, "Forbiden");
        require(order.account != address(0), "no-order");

        if (_sizeDelta > 0) {
            order.sizeDelta += uint256(_sizeDelta);
        } else if (_sizeDelta < 0) {
            require(order.sizeDelta > uint256(-_sizeDelta), "xS");
            order.sizeDelta -= uint256(-_sizeDelta);
        }

        if (_colDelta > 0) {
            order.collateralIn += uint128(_colDelta);
        } else if (_colDelta < 0) {
            require(order.collateralIn > uint256(-_colDelta), "xS");
            order.collateralIn -= uint128(-_colDelta);
        }

        if (_feeDelta > 0) {
            order.executionFee += uint128(_feeDelta);
        } else if (_feeDelta < 0) {
            require(order.executionFee >= uint128(-_feeDelta), "xS");
            order.executionFee -= uint128(-_feeDelta);
        }

        order.triggerPrice = _triggerPrice;
        order.triggerAboveThreshold = _triggerAboveThreshold;

        address _colToken = order.long0
            ? IRoxPerpPool(order.perpPool).token0()
            : IRoxPerpPool(order.perpPool).token1();
        int256 _inDelta = _colDelta + _feeDelta;
        if (_inDelta > 0) {
            if (order.shouldWarp) {
                require(uint256(_inDelta) == msg.value);
                _transferInETH();
            } else {
                TransferHelper.safeTransferFrom(
                    _colToken,
                    order.account,
                    address(this),
                    uint256(_inDelta)
                );
            }
        } else if (_inDelta < 0) {
            TransferHelper.safeTransfer(
                    _colToken,
                    order.account,
                    uint256(-_inDelta)
                );
            // IERC20(_colToken).safeTransfer(order.account, uint256(-_inDelta));
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
    ) external payable nonReentrant{
        address _account = msg.sender;
        address token0 = IRoxPerpPool(_perpPool).token0();
        address token1 = IRoxPerpPool(_perpPool).token1();
        address _colToken = _long0 ? token0 : token1;

        if (_shouldWarp) {
            require(_exeFee == msg.value);
            _transferInETH();
        } else {
            TransferHelper.safeTransferFrom(
                _colToken,
                _account,
                address(this),
                _exeFee
            );
        }

        uint256 _orderIndex = (decreaseOrdersIndex++);

        decreaseOrders[_orderIndex] = OrderData.DecreaseOrder({
            spotpool: IRoxPerpPool(_perpPool).spotPool(),
            account: _account,
            perpPool: _perpPool,
            token0: token0,
            token1: token1,
            key: _orderIndex,
            sizeDelta: _sizeDelta,
            collateralDelta: _colDelta,
            executionFee: _exeFee,
            long0: _long0,
            triggerAboveThreshold: _triggerAboveThreshold,
            shouldWarp: _shouldWarp,
            triggerPrice: _triggerPriceSqrtX96
        });
        decreaseOrderKeysAlive[address(0)].add(_orderIndex);
        decreaseOrderKeysAlive[_account].add(_orderIndex);
        emit CreateDecreaseOrder(decreaseOrders[_orderIndex]);
    }

    function cancelDecreaseOrder(uint256 _orderIndex) public nonReentrant {
        OrderData.DecreaseOrder memory order = decreaseOrders[_orderIndex];
        require(isDecreaseOrderKeyAlive(_orderIndex), "no-order");
        require(order.account == msg.sender, "OnlyOwner");
        decreaseOrderKeysAlive[order.account].remove(_orderIndex);
        decreaseOrderKeysAlive[address(0)].remove(_orderIndex);
        
        address _colToken = order.long0
            ? IRoxPerpPool(order.perpPool).token0()
            : IRoxPerpPool(order.perpPool).token1();

        uint256 tokenBack = order.executionFee;
        if (order.shouldWarp) {
            _transferOutETH(tokenBack, payable(msg.sender));
        } else {
            TransferHelper.safeTransfer(_colToken, msg.sender, tokenBack);
        }

        emit CancelDecreaseOrder(order);
        delete decreaseOrders[_orderIndex];
    }

    function executeDecreaseOrder(uint256 _key, address _feeReceipt) external nonReentrant {
        OrderData.DecreaseOrder memory order = decreaseOrders[_key];
        require(
            isDecreaseOrderKeyAlive(_key) && order.account != address(0),
            "no order"
        );

        (uint256 currentPrice, bool isValid) = validatePositionOrderPrice(
            order.perpPool,
            order.triggerAboveThreshold,
            order.triggerPrice
        );
        require(isValid, "Invalid Trig.Price");

        address _colToken = order.long0
            ? IRoxPerpPool(order.perpPool).token0()
            : IRoxPerpPool(order.perpPool).token1();

        IPerpRouter(perpRouter).decreasePosition(
            order.account,
            order.perpPool,
            order.collateralDelta,
            order.sizeDelta,
            order.long0,
            true,
            0
        );

        TransferHelper.safeTransfer(_colToken, _feeReceipt, order.executionFee);

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
        bool _triggerAboveThreshold
    ) public payable nonReentrant{
        require(isDecreaseOrderKeyAlive(_key), "no key");
        OrderData.DecreaseOrder memory order = decreaseOrders[_key];
        require(msg.sender == order.account, "Forbiden");
        require(order.account != address(0), "no-order");

        if (_sizeDelta > 0) {
            order.sizeDelta += uint256(_sizeDelta);
        } else if (_sizeDelta < 0) {
            require(order.sizeDelta > uint256(-_sizeDelta), "xS");
            order.sizeDelta -= uint256(-_sizeDelta);
        }

        if (_colDelta > 0) {
            order.collateralDelta += uint128(_colDelta);
        } else if (_colDelta < 0) {
            require(order.collateralDelta > uint256(-_colDelta), "xD");
            order.collateralDelta -= uint128(-_colDelta);
        }

        if (_feeDelta > 0) {
            order.executionFee += uint128(_feeDelta);
        } else if (_feeDelta < 0) {
            require(order.executionFee >= uint128(-_feeDelta), "xF");
            order.executionFee -= uint128(-_feeDelta);
        }

        order.triggerPrice = _triggerPrice;
        order.triggerAboveThreshold = _triggerAboveThreshold;

        address _colToken = order.long0
            ? IRoxPerpPool(order.perpPool).token0()
            : IRoxPerpPool(order.perpPool).token1();
        int256 _inDelta = _feeDelta;
        if (_inDelta > 0) {
            if (order.shouldWarp) {
                require(uint256(_inDelta) == msg.value);
                _transferInETH();
            } else {
                TransferHelper.safeTransferFrom(
                    _colToken,
                    order.account,
                    address(this),
                    uint256(_inDelta)
                );
            }
        } else if (_inDelta < 0) {
            TransferHelper.safeTransfer(_colToken, order.account, uint256(-_inDelta));
        }

        // sWrite to update
        decreaseOrders[_key] = order;
        emit UpdateDecreaseOrder(order);
    }

    //--------
    function _transferInETH() private {
        if (msg.value != 0) {
            IWETH9(weth).deposit{value: msg.value}();
        }
    }

    function _transferOutETH(
        uint256 _amountOut,
        address payable _receiver
    ) private {
        IWETH9(weth).withdraw(_amountOut);
        TransferHelper.safeTransferETH(_receiver, _amountOut);
    }

    function validatePositionOrderPrice(
        address _perpPool,
        bool _triggerAboveThreshold,
        uint256 _triggerPrice
    ) public view returns (uint256, bool) {
        uint256 currentPrice = IRoxUtils(roxUtils).getSqrtTwapX96(
            IRoxPerpPool(_perpPool).spotPool()
        );
        bool isPriceValid = _triggerAboveThreshold
            ? currentPrice > _triggerPrice
            : currentPrice < _triggerPrice;
        return (currentPrice, isPriceValid);
    }
}
