// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRiskVault} from "../interfaces/IRiskVault.sol";
import {Errors} from "../libraries/Errors.sol";
import {Events} from "../libraries/Events.sol";

contract RiskVault is IRiskVault {
    mapping(address => uint256) private _balances;

    function deposit(address account, uint256 amount) external override {
        if (account == address(0)) revert Errors.InvalidAddress();
        if (amount == 0) revert Errors.ZeroAmount();
        _balances[account] += amount;
        emit Events.Deposited(account, amount);
    }

    function withdraw(address account, uint256 amount) external override {
        if (account == address(0)) revert Errors.InvalidAddress();
        if (amount == 0) revert Errors.ZeroAmount();

        uint256 bal = _balances[account];
        if (bal < amount) revert Errors.InsufficientBalance();

        _balances[account] = bal - amount;
        emit Events.Withdrawn(account, amount);
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }
}