// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Errors} from "../libraries/Errors.sol";
import {Types} from "../libraries/Types.sol";
import {Events} from "../libraries/Events.sol";
import {Ownable} from "../vendor/openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "../vendor/openzeppelin/contracts/access/Ownable2Step.sol";
import {IRiskConfig} from "../interfaces/IRiskConfig.sol";

contract RiskConfig is Ownable2Step, IRiskConfig {
    error InvalidSigner();
    error InvalidBps();

    uint256 private constant BPS_DIVISOR = 10_000;
    uint256 private constant MAX_COVERAGE_RATIO_BPS = 5_000;
    uint256 private constant DEFAULT_LIQUIDATION_GRACE_PERIOD = 5 minutes;

    mapping(bytes32 marketId => Types.MarketConfig config) private _marketConfigs;

    uint256 private _maxCoverageRatioBps;
    uint256 private _premiumTreasuryBps;
    uint256 private _vaultUtilizationLimitBps;
    uint256 private _utilizationThrottleBps;
    uint256 private _liquidationPenaltyBps;
    uint256 private _liquidationGracePeriodSeconds;
    address private _quoteSigner;
    mapping(uint8 tier => uint256) private _maxCoverageRatioByTier;
    mapping(bytes32 marketId => uint256) private _maxInsurableAmountByMarket;
    mapping(bytes32 marketId => uint256) private _minHoldingTimeByMarket;
    mapping(bytes32 marketId => uint256) private _activationDelayByMarket;
    mapping(bytes32 marketId => uint256) private _fullActivationDelayByMarket;
    mapping(uint8 tier => uint256) private _cooldownSecondsByTier;

    event MaxCoverageRatioUpdated(uint256 previousValue, uint256 newValue);
    event PremiumTreasuryBpsUpdated(uint256 previousValue, uint256 newValue);
    event VaultUtilizationLimitBpsUpdated(uint256 previousValue, uint256 newValue);
    event UtilizationThrottleBpsUpdated(uint256 previousValue, uint256 newValue);
    event LiquidationPenaltyBpsUpdated(uint256 previousValue, uint256 newValue);
    event LiquidationGracePeriodUpdated(uint256 previousValue, uint256 newValue);
    event QuoteSignerUpdated(address indexed previousSigner, address indexed newSigner);
    event CoverageTierUpdated(uint8 indexed tier, uint256 maxCoverageRatioBps);
    event MarketInsuranceLimitsUpdated(
        bytes32 indexed marketId,
        uint256 maxInsurableAmount,
        uint256 minHoldingTime,
        uint256 activationDelay,
        uint256 fullActivationDelay
    );
    event TierCooldownUpdated(uint8 indexed tier, uint256 cooldownSeconds);

    /// @notice Deploys the RiskConfig with an initial owner and global risk parameters.
    /// @param initialOwner The governance owner with permission to update risk parameters.
    /// @param initialQuoteSigner Authorized signer for off-chain insurance quotes.
    /// @param initialMaxCoverageRatioBps Maximum insurance coverage ratio in basis points.
    /// @param initialPremiumTreasuryBps Premium share routed to treasury in basis points.
    /// @param initialVaultUtilizationLimitBps Max vault utilization allowed in basis points.
    /// @param initialLiquidationPenaltyBps Global liquidation penalty in basis points.
    constructor(
        address initialOwner,
        address initialQuoteSigner,
        uint256 initialMaxCoverageRatioBps,
        uint256 initialPremiumTreasuryBps,
        uint256 initialVaultUtilizationLimitBps,
        uint256 initialLiquidationPenaltyBps
    ) Ownable(initialOwner) {
        _setQuoteSigner(initialQuoteSigner);
        _setMaxCoverageRatioBps(initialMaxCoverageRatioBps);
        _setPremiumTreasuryBps(initialPremiumTreasuryBps);
        _setVaultUtilizationLimitBps(initialVaultUtilizationLimitBps);
        _setUtilizationThrottleBps(initialVaultUtilizationLimitBps);
        _setLiquidationPenaltyBps(initialLiquidationPenaltyBps);
        _setLiquidationGracePeriodSeconds(DEFAULT_LIQUIDATION_GRACE_PERIOD);
    }

    /// @notice Creates or updates market-level risk configuration.
    /// @param marketId Unique market identifier.
    /// @param config Risk configuration for the market.
    function setMarketConfig(bytes32 marketId, Types.MarketConfig calldata config) external onlyOwner {
        if (marketId == bytes32(0)) revert Errors.InvalidMarket();
        if (config.oracle == address(0) || config.collateralToken == address(0)) revert Errors.InvalidMarket();
        if (config.maxLeverageX18 == 0) revert Errors.InvalidLeverage();
        if (config.maintenanceMarginBps >= BPS_DIVISOR) revert InvalidBps();
        if (config.liquidationPenaltyBps > BPS_DIVISOR) revert InvalidBps();
        if (config.maxOpenInterestUsdX18 == 0) revert Errors.ZeroAmount();

        _marketConfigs[marketId] = config;

        emit Events.MarketConfigUpdated(
            marketId,
            config.oracle,
            config.collateralToken,
            config.maxLeverageX18,
            config.maintenanceMarginBps,
            config.liquidationPenaltyBps,
            config.maxOpenInterestUsdX18,
            config.isActive
        );
    }

    /// @notice Updates maximum insurance coverage ratio.
    /// @dev Value is capped to 50% (5000 bps).
    /// @param newMaxCoverageRatioBps Maximum coverage ratio in basis points.
    function setMaxCoverageRatioBps(uint256 newMaxCoverageRatioBps) external onlyOwner {
        _setMaxCoverageRatioBps(newMaxCoverageRatioBps);
    }

    /// @notice Updates premium treasury share.
    /// @param newPremiumTreasuryBps Treasury share in basis points.
    function setPremiumTreasuryBps(uint256 newPremiumTreasuryBps) external onlyOwner {
        _setPremiumTreasuryBps(newPremiumTreasuryBps);
    }

    /// @notice Updates vault utilization limit.
    /// @param newVaultUtilizationLimitBps Maximum utilization in basis points.
    function setVaultUtilizationLimitBps(uint256 newVaultUtilizationLimitBps) external onlyOwner {
        _setVaultUtilizationLimitBps(newVaultUtilizationLimitBps);
    }

    /// @notice Updates dynamic insurance utilization throttle.
    /// @param newUtilizationThrottleBps Throttle in basis points.
    function setUtilizationThrottleBps(uint256 newUtilizationThrottleBps) external onlyOwner {
        _setUtilizationThrottleBps(newUtilizationThrottleBps);
    }

    /// @notice Updates global liquidation penalty ratio.
    /// @param newLiquidationPenaltyBps Penalty ratio in basis points.
    function setLiquidationPenaltyBps(uint256 newLiquidationPenaltyBps) external onlyOwner {
        _setLiquidationPenaltyBps(newLiquidationPenaltyBps);
    }

    /// @notice Updates the liquidation grace period granted to insured positions before forced liquidation.
    /// @param newLiquidationGracePeriodSeconds Grace period duration in seconds.
    function setLiquidationGracePeriodSeconds(uint256 newLiquidationGracePeriodSeconds) external onlyOwner {
        _setLiquidationGracePeriodSeconds(newLiquidationGracePeriodSeconds);
    }

    /// @notice Updates authorized insurance quote signer.
    /// @param newQuoteSigner New signer address.
    function setQuoteSigner(address newQuoteSigner) external onlyOwner {
        _setQuoteSigner(newQuoteSigner);
    }

    /// @notice Sets coverage cap by user tier.
    /// @param tier Tier identifier.
    /// @param maxCoverageRatioBps_ Max coverage ratio for this tier.
    function setCoverageTier(uint8 tier, uint256 maxCoverageRatioBps_) external onlyOwner {
        if (maxCoverageRatioBps_ > MAX_COVERAGE_RATIO_BPS) revert Errors.InvalidCoverageRatio();
        _maxCoverageRatioByTier[tier] = maxCoverageRatioBps_;
        emit CoverageTierUpdated(tier, maxCoverageRatioBps_);
    }

    /// @notice Sets market-specific insurance limits.
    /// @param marketId Market identifier.
    /// @param maxInsurableAmount Max insurable notional amount.
    /// @param minHoldingTime Min holding seconds before claim eligibility.
    /// @param activationDelay Delay before insurance starts scaling in.
    /// @param fullActivationDelay Delay when full coverage is reached.
    function setMarketInsuranceLimits(
        bytes32 marketId,
        uint256 maxInsurableAmount,
        uint256 minHoldingTime,
        uint256 activationDelay,
        uint256 fullActivationDelay
    ) external onlyOwner {
        if (marketId == bytes32(0) || maxInsurableAmount == 0) revert Errors.InvalidMarket();
        if (fullActivationDelay < activationDelay) revert InvalidBps();

        _maxInsurableAmountByMarket[marketId] = maxInsurableAmount;
        _minHoldingTimeByMarket[marketId] = minHoldingTime;
        _activationDelayByMarket[marketId] = activationDelay;
        _fullActivationDelayByMarket[marketId] = fullActivationDelay;
        emit MarketInsuranceLimitsUpdated(
            marketId, maxInsurableAmount, minHoldingTime, activationDelay, fullActivationDelay
        );
    }

    /// @notice Sets claim cooldown by tier.
    /// @param tier Tier identifier.
    /// @param cooldownSeconds Cooldown duration in seconds.
    function setTierCooldown(uint8 tier, uint256 cooldownSeconds) external onlyOwner {
        _cooldownSecondsByTier[tier] = cooldownSeconds;
        emit TierCooldownUpdated(tier, cooldownSeconds);
    }

    /// @notice Returns market risk configuration.
    /// @param marketId Unique market identifier.
    /// @return config Market configuration snapshot.
    function getMarketConfig(bytes32 marketId) external view override returns (Types.MarketConfig memory config) {
        return _marketConfigs[marketId];
    }

    /// @notice Returns all global risk parameters used by insurance and liquidation modules.
    function getGlobalParams()
        external
        view
        returns (
            uint256 maxCoverageRatioBps_,
            uint256 premiumTreasuryBps_,
            uint256 vaultUtilizationLimitBps_,
            uint256 liquidationPenaltyBps_,
            address quoteSigner_
        )
    {
        return (
            _maxCoverageRatioBps,
            _premiumTreasuryBps,
            _vaultUtilizationLimitBps,
            _liquidationPenaltyBps,
            _quoteSigner
        );
    }

    /// @notice Returns the maximum insurance coverage ratio (in bps).
    function maxCoverageRatioBps() external view override returns (uint256) {
        return _maxCoverageRatioBps;
    }

    /// @notice Returns the premium share that routes to treasury (in bps).
    function premiumTreasuryBps() external view override returns (uint256) {
        return _premiumTreasuryBps;
    }

    /// @notice Returns the maximum vault utilization limit (in bps).
    function vaultUtilizationLimitBps() external view override returns (uint256) {
        return _vaultUtilizationLimitBps;
    }

    /// @notice Returns dynamic utilization throttle for accepting new coverage.
    function utilizationThrottleBps() external view override returns (uint256) {
        return _utilizationThrottleBps;
    }

    /// @notice Returns the global liquidation penalty (in bps).
    function liquidationPenaltyBps() external view override returns (uint256) {
        return _liquidationPenaltyBps;
    }

    /// @notice Returns liquidation grace period in seconds for insured positions.
    function liquidationGracePeriodSeconds() external view override returns (uint256) {
        return _liquidationGracePeriodSeconds;
    }

    /// @notice Returns the authorized off-chain quote signer.
    function quoteSigner() external view override returns (address) {
        return _quoteSigner;
    }

    /// @notice Returns max coverage ratio for a tier. Falls back to global cap when not set.
    function maxCoverageRatioByTier(uint8 tier) external view override returns (uint256) {
        uint256 tierCap = _maxCoverageRatioByTier[tier];
        return tierCap == 0 ? _maxCoverageRatioBps : tierCap;
    }

    /// @notice Returns market max insurable amount.
    function maxInsurableAmountByMarket(bytes32 marketId) external view override returns (uint256) {
        return _maxInsurableAmountByMarket[marketId];
    }

    /// @notice Returns minimum holding time required for claims in a market.
    function minHoldingTimeByMarket(bytes32 marketId) external view override returns (uint256) {
        return _minHoldingTimeByMarket[marketId];
    }

    /// @notice Returns activation delay for staged coverage in a market.
    function activationDelayByMarket(bytes32 marketId) external view override returns (uint256) {
        return _activationDelayByMarket[marketId];
    }

    /// @notice Returns full activation delay for staged coverage in a market.
    function fullActivationDelayByMarket(bytes32 marketId) external view override returns (uint256) {
        return _fullActivationDelayByMarket[marketId];
    }

    /// @notice Returns claim cooldown duration for a tier.
    function cooldownSecondsByTier(uint8 tier) external view override returns (uint256) {
        return _cooldownSecondsByTier[tier];
    }

    function _setMaxCoverageRatioBps(uint256 newValue) internal {
        if (newValue > MAX_COVERAGE_RATIO_BPS) revert Errors.InvalidCoverageRatio();
        uint256 previous = _maxCoverageRatioBps;
        _maxCoverageRatioBps = newValue;
        emit MaxCoverageRatioUpdated(previous, newValue);
    }

    function _setPremiumTreasuryBps(uint256 newValue) internal {
        if (newValue > BPS_DIVISOR) revert InvalidBps();
        uint256 previous = _premiumTreasuryBps;
        _premiumTreasuryBps = newValue;
        emit PremiumTreasuryBpsUpdated(previous, newValue);
    }

    function _setVaultUtilizationLimitBps(uint256 newValue) internal {
        if (newValue == 0 || newValue > BPS_DIVISOR) revert InvalidBps();
        uint256 previous = _vaultUtilizationLimitBps;
        _vaultUtilizationLimitBps = newValue;
        emit VaultUtilizationLimitBpsUpdated(previous, newValue);
    }

    function _setLiquidationPenaltyBps(uint256 newValue) internal {
        if (newValue > BPS_DIVISOR) revert InvalidBps();
        uint256 previous = _liquidationPenaltyBps;
        _liquidationPenaltyBps = newValue;
        emit LiquidationPenaltyBpsUpdated(previous, newValue);
    }

    function _setLiquidationGracePeriodSeconds(uint256 newValue) internal {
        uint256 previous = _liquidationGracePeriodSeconds;
        _liquidationGracePeriodSeconds = newValue;
        emit LiquidationGracePeriodUpdated(previous, newValue);
    }

    function _setUtilizationThrottleBps(uint256 newValue) internal {
        if (newValue == 0 || newValue > BPS_DIVISOR) revert InvalidBps();
        uint256 previous = _utilizationThrottleBps;
        _utilizationThrottleBps = newValue;
        emit UtilizationThrottleBpsUpdated(previous, newValue);
    }

    function _setQuoteSigner(address newSigner) internal {
        if (newSigner == address(0)) revert InvalidSigner();
        address previous = _quoteSigner;
        _quoteSigner = newSigner;
        emit QuoteSignerUpdated(previous, newSigner);
    }
}
