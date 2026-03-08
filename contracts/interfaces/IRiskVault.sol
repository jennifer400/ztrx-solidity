// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRiskVault {
    function totalAssets() external view returns (uint256);
    function totalReserved() external view returns (uint256);
    /// @notice Adds collateral assets to the vault.
    function fundVault(uint256 amount) external;
    /// @notice Reserves claim capacity for a position.
    function reserveCapacity(uint256 positionId, uint256 amount) external;
    /// @notice Releases reserved claim capacity for a position.
    function releaseCapacity(uint256 positionId) external;
    /// @notice Accepts premium income into vault assets.
    function receivePremium(uint256 amount) external;
    /// @notice Pays a liquidation claim for a position.
    function payClaim(uint256 positionId, address recipient, uint256 amount) external;
    /// @notice Returns remaining reservable capacity.
    function getAvailableCapacity() external view returns (uint256);
    /// @notice Returns reserved amount for a position.
    function getReservedAmount(uint256 positionId) external view returns (uint256);
}
