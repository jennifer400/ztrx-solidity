// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IInsuranceController {
    struct SignedInsuranceQuote {
        address user;
        bytes32 marketId;
        bool side;
        uint256 leverageX18;
        uint256 sizeUsdX18;
        uint256 premiumBps;
        uint256 coverageRatioBps;
        uint256 maxInsurableAmount;
        uint256 minHoldingTime;
        uint256 cooldownSeconds;
        uint256 activationDelay;
        uint256 fullActivationDelay;
        uint8 userTier;
        uint8 marketTier;
        uint256 expiry;
        uint256 nonce;
        bytes32 modelVersion;
    }

    /// @notice Registers insurance coverage and reserves vault capacity for a position.
    function registerCoverage(uint256 positionId, SignedInsuranceQuote calldata quote, bytes calldata signature) external;
    /// @notice Settles premium on profitable close.
    function settlePremiumOnProfit(uint256 positionId, address payer, uint256 realizedProfit)
        external
        returns (uint256 premiumCharged);
    /// @notice Processes liquidation claim payout for insured position.
    function processLiquidationClaim(uint256 positionId, address recipient, uint256 realizedLoss, bool eligible)
        external
        returns (uint256 claimPaid);
    /// @notice Cancels active coverage when position closes without claim.
    function cancelCoverageOnClose(uint256 positionId) external;
    /// @notice Verifies off-chain insurance quote signature.
    function verifyQuote(SignedInsuranceQuote calldata quote, bytes calldata signature) external view returns (bool);

    /// @notice Optional hook called when a position opens.
    function onPositionOpened(address user, bytes32 marketId, uint256 positionId, bytes32 insuranceTermId)
        external
        returns (bool);
    /// @notice Optional hook called when a position closes.
    function onPositionClosed(address user, bytes32 marketId, uint256 positionId, bytes32 insuranceTermId) external;
    /// @notice Optional hook called when a position is liquidated.
    function onPositionLiquidated(address user, bytes32 marketId, uint256 positionId, bytes32 insuranceTermId) external;
}
