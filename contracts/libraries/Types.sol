// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Types {
    enum PositionStatus {
        None,
        Open,
        Closed,
        Liquidated
    }

    enum InsuranceStatus {
        None,
        Active,
        Settled,
        Expired
    }

    struct Position {
        uint256 id;
        address trader;
        bytes32 marketId;
        address collateralToken;
        uint256 collateralAmount;
        uint256 sizeUsdX18;
        uint256 entryPriceX18;
        uint256 leverageX18;
        bool isLong;
        PositionStatus status;
        InsuranceStatus insuranceStatus;
        uint64 openedAt;
        uint64 closedAt;
        bytes32 insuranceTermId;
    }

    struct InsuranceTerms {
        uint256 insuranceId;
        uint256 positionId;
        uint256 coverageRatioBps;
        uint256 premiumRateBps;
        uint256 reservedAmount;
        uint64 startTime;
        uint64 endTime;
        InsuranceStatus status;
    }

    struct MarketConfig {
        bool isActive;
        address oracle;
        address collateralToken;
        uint256 maxLeverageX18;
        uint256 maintenanceMarginBps;
        uint256 liquidationPenaltyBps;
        uint256 maxOpenInterestUsdX18;
    }

    struct VaultAccounting {
        uint256 totalAssets;
        uint256 totalReserved;
        uint256 totalClaimsPaid;
        uint256 totalPremiumAccrued;
    }

    struct SignedInsuranceQuote {
        bytes32 quoteId;
        address trader;
        bytes32 marketId;
        uint256 positionId;
        uint256 coverageRatioBps;
        uint256 premiumRateBps;
        uint256 reservedAmount;
        uint64 validUntil;
        uint256 nonce;
        address signer;
        bytes signature;
    }
}
