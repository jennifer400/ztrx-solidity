// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracleAdapter {
    /// @notice Returns validated mark price for a market, normalized to 1e18 decimals.
    /// @param marketId Market identifier.
    function getMarkPrice(bytes32 marketId) external view returns (uint256 priceX18);
    /// @notice Returns validated index price for a market, normalized to 1e18 decimals.
    /// @param marketId Market identifier.
    function getIndexPrice(bytes32 marketId) external view returns (uint256 priceX18);
}
