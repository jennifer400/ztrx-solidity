// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracleAdapter {
    function getPrice(address asset) external view returns (uint256 priceX18, uint256 updatedAt);
}