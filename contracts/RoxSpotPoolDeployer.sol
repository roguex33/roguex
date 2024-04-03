// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IRoxSpotPoolDeployer.sol';

import './RoxSpotPool.sol';

contract RoxSpotPoolDeployer is IRoxSpotPoolDeployer {

    address public deployFactory;

    struct Parameters {
        address factory;
        address token0;
        address token1;
        uint24 fee;
        address perpPool;
        address posnPool;
        address roxUtils;
    }
    constructor(address _deployFactory){
        deployFactory = _deployFactory;
    }
    /// @inheritdoc IRoxSpotPoolDeployer
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
        address perpPool,
        address posnPool,
        address roxUtils
    ) external override returns (address pool) {
        require(deployFactory == msg.sender, "F");
        parameters = Parameters({factory: factory, token0: token0, token1: token1, fee: fee, perpPool:perpPool, posnPool:posnPool, roxUtils:roxUtils});
        pool = address(new RoxSpotPool{salt: keccak256(abi.encode(token0, token1, fee))}());
        delete parameters;
    }
    
}
