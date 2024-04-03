// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/access/Ownable.sol";

enum YieldMode {
    AUTOMATIC,
    VOID,
    CLAIMABLE
}


enum GasMode {
    VOID,
    CLAIMABLE 
}


interface IWETHUSDBRebasing {
    function configure(YieldMode) external returns (uint256);
}

interface IBlast{
    // // configure
    function configureContract(address contractAddress, YieldMode _yield, GasMode gasMode, address governor) external;
    function configure(YieldMode _yield, GasMode gasMode, address governor) external;

    // // base configuration options
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

    // // claim yield
    function claimYield(address contractAddress, address recipientOfYield, uint256 amount) external returns (uint256);
    function claimAllYield(address contractAddress, address recipientOfYield) external returns (uint256);

    // // claim gas
    function claimAllGas(address contractAddress, address recipientOfGas) external returns (uint256);
    function claimGasAtMinClaimRate(address contractAddress, address recipientOfGas, uint256 minClaimRateBips) external returns (uint256);
    function claimMaxGas(address contractAddress, address recipientOfGas) external returns (uint256);
    function claimGas(address contractAddress, address recipientOfGas, uint256 gasToClaim, uint256 gasSecondsToConsume) external returns (uint256);

    // // read functions
    function readClaimableYield(address contractAddress) external view returns (uint256);
    function readYieldConfiguration(address contractAddress) external view returns (uint8);
    function readGasParams(address contractAddress) external view returns (uint256 etherSeconds, uint256 etherBalance, uint256 lastUpdated, GasMode);
}


contract BlastYield is Ownable{
    
    address constant public blast = 0x4300000000000000000000000000000000000002;

    // constructor() {
    //         // //configure claimable yield for USDB
    //         // IWETHUSDBRebasing(0x4200000000000000000000000000000000000022).configure(YieldMode.CLAIMABLE);

    //         // //configure claimable yield for WETH
    //         // IWETHUSDBRebasing(0x4200000000000000000000000000000000000023).configure(YieldMode.CLAIMABLE);

    //         // IBlast(0x4300000000000000000000000000000000000002).configureClaimableGas();
	// 	    // IBlast(0x4300000000000000000000000000000000000002).configureGovernor(0x8792122Ce00f815b7bCf8e26D0B58eDdc961d35D);
    // }

    mapping(address => bool) public isHandler;

    event SetHandler(address handler, bool status);

    modifier onlyHandler() {
        require(isHandler[msg.sender], "forbidden hadler");
        _;
    }

    function setHandler(address _handler, bool _state) external onlyOwner{
        isHandler[_handler] =  _state;
        emit SetHandler(_handler, _state);
    }
    
    function claimAllYield(address contractAddress, address recipientOfYield) external onlyHandler returns (uint256){
        return IBlast(blast).claimAllYield(contractAddress, recipientOfYield);
    }

    function claimAllGas(address contractAddress, address recipientOfGas) external onlyHandler returns (uint256){
        return IBlast(blast).claimAllGas(contractAddress, recipientOfGas);
    }

    function configureClaimableYieldOnBehalf(address contractAddress) external onlyHandler{
        IBlast(blast).configureClaimableYieldOnBehalf(contractAddress);
    }

    function configureAutomaticYieldOnBehalf(address contractAddress) external onlyHandler{
        IBlast(blast).configureAutomaticYieldOnBehalf(contractAddress);
    }

    function configureVoidYieldOnBehalf(address contractAddress) external onlyHandler{
        IBlast(blast).configureVoidYieldOnBehalf(contractAddress);
    }

    function configureClaimableGasOnBehalf(address contractAddress) external onlyHandler{
        IBlast(blast).configureClaimableGasOnBehalf(contractAddress);
    }

    function configureVoidGasOnBehalf(address contractAddress) external onlyHandler{
        IBlast(blast).configureVoidGasOnBehalf(contractAddress);
    }

    function configureGovernor(address _governor) external onlyHandler{
        IBlast(blast).configureGovernor(_governor);
    }
    function configureGovernorOnBehalf(address _newGovernor, address contractAddress)external onlyHandler{
        IBlast(blast).configureGovernorOnBehalf(_newGovernor, contractAddress);
    }

    function multicall(bytes[] calldata data) public payable onlyOwner returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success) {
                if (result.length < 68) revert();
                assembly {
                    result := add(result, 0x04)
                }
                revert(abi.decode(result, (string)));
            }

            results[i] = result;
        }
    }

}