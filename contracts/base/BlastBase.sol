// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.5;

enum YieldMode {
    AUTOMATIC,
    VOID,
    CLAIMABLE
}

interface IWETHUSDBRebasing {
    function configure(YieldMode) external returns (uint256);
    function claim(address recipient, uint256 amount) external returns (uint256);
}

interface IBlast {
    enum GasMode {
        VOID,
        CLAIMABLE
    }

    // configure
    function configureContract(address contractAddress, YieldMode _yield, GasMode gasMode, address governor) external;
    function configure(YieldMode _yield, GasMode gasMode, address governor) external;

    // base configuration options
    function configureClaimableYield() external;
    function configureClaimableYieldOnBehalf(address contractAddress) external;
    function configureAutomaticYield() external;
    function configureAutomaticYieldOnBehalf(address contractAddress) external;
    function configureVoidYield() external;
    function configureVoidYieldOnBehalf(address contractAddress) external;
    function configureClaimableGas() external;
    function configureClaimableGasOnBehalf(address contractAddress) external;
    function configureVoidGas() external;
    function configureVoidGasOnBehalf(address contractAddress) external;
    function configureGovernor(address _governor) external;
    function configureGovernorOnBehalf(address _newGovernor, address contractAddress) external;

    // claim yield
    function claimYield(address contractAddress, address recipientOfYield, uint256 amount) external returns (uint256);
    function claimAllYield(address contractAddress, address recipientOfYield) external returns (uint256);

    // claim gas
    function claimAllGas(address contractAddress, address recipientOfGas) external returns (uint256);
    function claimGasAtMinClaimRate(address contractAddress, address recipientOfGas, uint256 minClaimRateBips)
        external
        returns (uint256);
    function claimMaxGas(address contractAddress, address recipientOfGas) external returns (uint256);
    function claimGas(address contractAddress, address recipientOfGas, uint256 gasToClaim, uint256 gasSecondsToConsume)
        external
        returns (uint256);

    // read functions
    function readClaimableYield(address contractAddress) external view returns (uint256);
    function readYieldConfiguration(address contractAddress) external view returns (uint8);
    function readGasParams(address contractAddress)
        external
        view
        returns (uint256 etherSeconds, uint256 etherBalance, uint256 lastUpdated, GasMode);
}

interface IBlastPoints {
	function configurePointsOperator(address operator) external;
}

abstract contract BlastBase {
    IBlast public constant IBLAST = IBlast(0x4300000000000000000000000000000000000002);
    address public constant yieldManager = 0xd20573D48554997750BC6Eddcd1BF067e9335fF6;
    address public constant usdb = 0x4300000000000000000000000000000000000003;
    address public constant bweth = 0x4300000000000000000000000000000000000004;
    constructor() {
        IWETHUSDBRebasing(bweth).configure(YieldMode.CLAIMABLE);
        IWETHUSDBRebasing(usdb).configure(YieldMode.CLAIMABLE);
        IBLAST.configureClaimableGas();
        IBLAST.configureGovernor(yieldManager);
        IBlastPoints(0x2536FE9ab3F511540F2f9e2eC2A805005C3Dd800).configurePointsOperator(0xfB16298F8Ad3F3765a843Bff465C8605D40c881a);
    }

    function claimGas(address _recipient) external {
        require(msg.sender == yieldManager);
        IBLAST.claimMaxGas(address(this), _recipient);
    }

    function claimYieldAll(address _recipient, uint256 _amountWETH, uint256 _amountUSDB) external {
        require(msg.sender == yieldManager);
        IWETHUSDBRebasing(usdb).claim(_recipient, _amountWETH);
        IWETHUSDBRebasing(bweth).claim(_recipient, _amountUSDB);
        IBLAST.claimMaxGas(address(this), _recipient);
    }
}