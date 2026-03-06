// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract LiquidationEngine {
    function canLiquidate(uint256 margin, uint256 maintenanceMargin) external pure returns (bool) {
        return margin < maintenanceMargin;
    }
}