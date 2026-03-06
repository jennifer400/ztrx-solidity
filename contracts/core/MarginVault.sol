// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Errors} from "../libraries/Errors.sol";
import {Events} from "../libraries/Events.sol";

contract MarginVault {
    mapping(address => uint256) public collateral;

    function deposit() external payable {
        if (msg.value == 0) revert Errors.ZeroAmount();
        collateral[msg.sender] += msg.value;
        emit Events.Deposited(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        if (amount == 0) revert Errors.ZeroAmount();
        uint256 bal = collateral[msg.sender];
        if (bal < amount) revert Errors.InsufficientBalance();

        collateral[msg.sender] = bal - amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "TRANSFER_FAILED");
        emit Events.Withdrawn(msg.sender, amount);
    }
}