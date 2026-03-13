// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRiskVault {
    function totalAssets() external view returns (uint256);
    function totalReserved() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function shareBalanceOf(address provider) external view returns (uint256);
    function principalBalanceOf(address provider) external view returns (uint256);
    function lpUnlockTime(address provider) external view returns (uint256);
    /// @notice Adds collateral assets to the vault.
    function fundVault(uint256 amount) external;
    /// @notice Adds LP liquidity and mints vault shares.
    function depositLiquidity(uint256 amount) external returns (uint256 sharesMinted);
    /// @notice Redeems vault shares for currently available assets.
    function redeemLiquidity(uint256 shares) external returns (uint256 assetsReturned);
    /// @notice Claims LP yield only and burns the shares required to realize it.
    function claimYield(uint256 amount) external returns (uint256 assetsClaimed, uint256 sharesBurned);
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
    /// @notice Returns unreserved assets that can currently be withdrawn by LPs.
    function getAvailableLiquidity() external view returns (uint256);
    /// @notice Converts an asset deposit amount into LP shares.
    function previewDeposit(uint256 amount) external view returns (uint256 sharesMinted);
    /// @notice Converts share amount into redeemable assets.
    function previewRedeem(uint256 shares) external view returns (uint256 assetsReturned);
    /// @notice Returns current asset value for an LP position.
    function lpAssetValue(address provider) external view returns (uint256 assetValue);
    /// @notice Returns currently claimable profit above tracked principal.
    function claimableYieldOf(address provider) external view returns (uint256 yieldAmount);
}
