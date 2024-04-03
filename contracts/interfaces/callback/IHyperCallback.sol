// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

interface IHyperCallback {
    function rebalanceCallback() external returns (
        int24 mTickLower,
        int24 mTickUpper,
        uint128 mAmount,
        bytes memory data);

}
