// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Errors {
    error Unauthorized();
    error InvalidMarket();
    error InvalidSignature();
    error QuoteAlreadyUsed();
    error InsufficientMargin();
    error InsufficientBalance();
    error InvalidLeverage();
    error InvalidCoverageRatio();
    error InactivePosition();
    error InvalidLiquidationState();
    error InsuranceNotActive();
    error QuoteExpired();
    error VaultCapacityExceeded();
    error InvalidAddress();
    error ZeroAmount();
    error InvalidOracleConfig();
    error StalePrice();
    error InvalidPrice();
    error PriceDeviationTooHigh();
    error CooldownActive();
    error MinHoldingNotMet();
    error CoverageNotEffective();
    error ExceedsMaxInsurableAmount();
}
