// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

interface ISwapMining {
    function depositSwap(
        address _pool,
        uint256 _amount,
        address _recipient
    ) external;
}
