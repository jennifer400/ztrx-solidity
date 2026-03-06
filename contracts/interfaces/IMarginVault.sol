// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMarginVault {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function transferOut(address user, uint256 amount) external;
    function lockMargin(address user, uint256 amount) external;
    function unlockMargin(address user, uint256 amount) external;
    function transferSettlement(address to, uint256 amount) external;
    function availableBalance(address user) external view returns (uint256 amount);
    function totalBalance(address user) external view returns (uint256 amount);
    function lockedMargin(address user) external view returns (uint256 amount);
}
