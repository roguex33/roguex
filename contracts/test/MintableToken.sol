// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MintableToken is ERC20, Ownable {
    mapping (address => bool) public isMinter;
    
    modifier onlyMinter() {
        require(isMinter[msg.sender], "forbidden");
        _;
    }

    event SetMinter(address minter, bool status);

    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        isMinter[msg.sender] = true;

    }
    
    function setMinter(address _minter, bool _isActive) external onlyOwner {
        isMinter[_minter] = _isActive;
        emit SetMinter(_minter, _isActive);
    }

    function mint(address _account, uint256 _amount) external onlyMinter {
        _mint(_account, _amount);
    }

    function burn(uint256 _amount) external  {
        _burn(msg.sender, _amount);
    }
}
