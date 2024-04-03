// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.5;

enum YieldMode {
    AUTOMATIC,
    VOID,
    CLAIMABLE
}

interface IWETHUSDBRebasing {
    function configure(YieldMode) external returns (uint256);
}

interface IBlast{
    function configureClaimableGas() external;
    function configureGovernor(address _governor) external;

}

// BlastYieldContract  : 0x4300000000000000000000000000000000000002
// Blast WETH rebasing : 0x4300000000000000000000000000000000000002
// Blast USDB rebasing : 0x4200000000000000000000000000000000000023
abstract contract BlastBase {
    
    constructor() {
            IWETHUSDBRebasing(0x4300000000000000000000000000000000000004).configure(YieldMode.CLAIMABLE);
            IWETHUSDBRebasing(0x4300000000000000000000000000000000000003).configure(YieldMode.CLAIMABLE);
            IBlast(0x4300000000000000000000000000000000000002).configureClaimableGas();
		    IBlast(0x4300000000000000000000000000000000000002).configureGovernor(0x05956a4674945DEE1E00442a53c562350282C340);
    }

}