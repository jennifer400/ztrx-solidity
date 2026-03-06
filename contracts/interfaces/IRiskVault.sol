// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRiskVault {
    function deposit(address account, uint256 amount) external;
    function withdraw(address account, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}