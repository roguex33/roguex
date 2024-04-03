// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;


interface IRoxPosnPoolDeployer {

    function parameters()
        external
        view
        returns (
            address factory,
            address token0,
            address token1,
            uint24 fee,
            address spotPool,
            address perpPool

        );
    function deploy(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        address spotPool,
        address perpPool
    ) external returns (address pool);
}
