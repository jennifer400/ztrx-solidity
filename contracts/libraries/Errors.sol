// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Errors {
    error Unauthorized();
    error InvalidMarket();
    error InsufficientMargin();
    error InvalidLeverage();
    error InvalidCoverageRatio();
    error InactivePosition();
    error InvalidLiquidationState();
    error InsuranceNotActive();
    error QuoteExpired();
    error VaultCapacityExceeded();
    error ZeroAmount();
}
