// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IRoxPosnPoolDeployer.sol';
import './RoxPosnPool.sol';

contract RoxPosnPoolDeployer is IRoxPosnPoolDeployer {

    address public deployFactory;

    struct Parameters {
        address factory;
        address token0;
        address token1;
        uint24 fee;
        address spotPool;
        address perpPool;
    }
    constructor(address _deployFactory){
        deployFactory = _deployFactory;
    }
    Parameters public override parameters;

    function deploy(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        address spotPool,
        address perpPool
    ) external override returns (address pool) {
        require(deployFactory == msg.sender, "F");
        parameters = Parameters({factory: factory, token0: token0, token1: token1, fee: fee, spotPool:spotPool, perpPool:perpPool});
        pool = address(new RoxPosnPool{salt: keccak256(abi.encode(token0, token1, fee))}());
        delete parameters;
    }
}
