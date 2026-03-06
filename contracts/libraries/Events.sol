// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Events {
    event Deposited(address indexed account, address indexed token, uint256 amount);
    event Withdrawn(address indexed account, address indexed token, uint256 amount);

    event PositionOpened(
        uint256 indexed positionId,
        address indexed trader,
        bytes32 indexed marketId,
        uint256 sizeUsdX18,
        uint256 collateralAmount,
        uint256 entryPriceX18,
        bool isLong
    );
    event PositionIncreased(uint256 indexed positionId, uint256 newSizeUsdX18, uint256 addedCollateral);
    event PositionReduced(uint256 indexed positionId, uint256 reducedSizeUsdX18, int256 realizedPnl);
    event PositionClosed(uint256 indexed positionId, int256 realizedPnl, uint256 exitPriceX18);

    event InsuranceActivated(
        uint256 indexed insuranceId,
        uint256 indexed positionId,
        bytes32 indexed quoteId,
        uint256 coverageRatioBps,
        uint256 premiumRateBps,
        uint256 reservedAmount
    );
    event PremiumSettled(
        uint256 indexed insuranceId,
        uint256 indexed positionId,
        address indexed trader,
        address token,
        uint256 premiumAmount
    );
    event ClaimPaid(
        uint256 indexed insuranceId,
        uint256 indexed positionId,
        address indexed beneficiary,
        address token,
        uint256 claimAmount
    );

    event LiquidationTriggered(uint256 indexed positionId, address indexed liquidator, uint256 markPriceX18);
    event LiquidationCompleted(
        uint256 indexed positionId,
        address indexed liquidator,
        int256 realizedPnl,
        uint256 insurancePayout
    );

    event VaultFunded(address indexed funder, address indexed token, uint256 amount, uint256 totalAssets);
    event VaultReserved(uint256 indexed insuranceId, uint256 amount, uint256 totalReserved);
    event VaultReserveReleased(uint256 indexed insuranceId, uint256 amount, uint256 totalReserved);

    event MarketConfigUpdated(
        bytes32 indexed marketId,
        address indexed oracle,
        address indexed collateralToken,
        uint256 maxLeverageX18,
        uint256 maintenanceMarginBps,
        uint256 liquidationPenaltyBps,
        uint256 maxOpenInterestUsdX18,
        bool isActive
    );
}
