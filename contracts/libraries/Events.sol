// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Events {
    event PriceUpdated(address indexed asset, uint256 priceX18, uint256 updatedAt);
    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event LossCovered(uint256 requested, uint256 covered);
}