// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Events {
    event Deposited(address indexed account, address indexed token, uint256 amount);
    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, address indexed token, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event PriceUpdated(address indexed asset, uint256 priceX18, uint256 updatedAt);
    event OracleMarketConfigured(
        bytes32 indexed marketId,
        address indexed markFeed,
        address indexed indexFeed,
        uint32 maxStaleness,
        uint16 maxDeviationBps,
        uint256 minPriceX18,
        uint256 maxPriceX18
    );
    event LossCovered(uint256 requested, uint256 covered);

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
    event InsuranceCancelled(uint256 indexed insuranceId, uint256 indexed positionId);

    event LiquidationTriggered(uint256 indexed positionId, address indexed liquidator, uint256 markPriceX18);
    event LiquidationCompleted(
        uint256 indexed positionId,
        address indexed liquidator,
        int256 realizedPnl,
        uint256 insurancePayout
    );

    event VaultFunded(address indexed funder, address indexed token, uint256 amount, uint256 totalAssets);
    event VaultPremiumReceived(address indexed payer, address indexed token, uint256 amount, uint256 totalAssets);
    event VaultLiquidityDeposited(
        address indexed provider,
        address indexed token,
        uint256 assetAmount,
        uint256 shareAmount,
        uint256 totalAssets,
        uint256 totalShares
    );
    event VaultLiquidityWithdrawn(
        address indexed provider,
        address indexed token,
        uint256 assetAmount,
        uint256 shareAmount,
        uint256 totalAssets,
        uint256 totalShares
    );
    event VaultYieldClaimed(
        address indexed provider,
        address indexed token,
        uint256 assetAmount,
        uint256 shareAmount,
        uint256 remainingPrincipal,
        uint256 totalAssets,
        uint256 totalShares
    );
    event VaultReserved(uint256 indexed insuranceId, uint256 amount, uint256 totalReserved);
    event VaultReserveReleased(uint256 indexed insuranceId, uint256 amount, uint256 totalReserved);
    event VaultClaimPaid(
        uint256 indexed positionId, address indexed recipient, address indexed token, uint256 amount, uint256 totalAssets
    );
    event MarginLocked(address indexed account, uint256 amount, uint256 newLockedMargin);
    event MarginUnlocked(address indexed account, uint256 amount, uint256 newLockedMargin);
    event SettlementTransferred(address indexed to, address indexed token, uint256 amount);

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
