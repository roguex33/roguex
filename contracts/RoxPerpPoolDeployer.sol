// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import "./libraries/TradeMath.sol";
import './interfaces/IRoxPerpPoolDeployer.sol';
import './RoxPerpPool.sol';

contract RoxPerpPoolDeployer is IRoxPerpPoolDeployer {

    address immutable public deployFactory;

    struct Parameters {
        address factory;
        address token0;
        address token1;
        uint24 fee;
        address spotPool;
        address posnPool;
    }
    constructor(address _deployFactory){
        deployFactory = _deployFactory;
    }
    /// @inheritdoc IRoxPerpPoolDeployer
    Parameters public override parameters;

    /// @dev Deploys a pool with the given parameters by transiently setting the parameters storage slot and then
    /// clearing it after deploying the pool.
    /// @param factory The contract address of the roguex factory
    /// @param token0 The first token of the pool by address sort order
    /// @param token1 The second token of the pool by address sort order
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    function deploy(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        address spotPool,
        address posnPool
    ) external override returns (address pool) {
        require(deployFactory == msg.sender, "F");
        parameters = Parameters({factory: factory, token0: token0, token1: token1, fee: fee, spotPool:spotPool,posnPool:posnPool});
        pool = address(new RoxPerpPool{salt: keccak256(abi.encode(token0, token1, fee))}());
        delete parameters;
    }
}
