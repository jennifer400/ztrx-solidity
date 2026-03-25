// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILiquidationEngine {
    function isLiquidatable(address user, bytes32 marketId) external view returns (bool liquidatable);
    function getGracePeriodExpiry(address user, bytes32 marketId) external view returns (uint256 expiry);
    function liquidate(address user, bytes32 marketId) external;
    function onMarginUpdated(address user, bytes32 marketId) external;
}
