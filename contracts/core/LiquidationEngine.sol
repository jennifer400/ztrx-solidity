// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "../libraries/Types.sol";
import {Errors} from "../libraries/Errors.sol";
import {Events} from "../libraries/Events.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IRiskConfig} from "../interfaces/IRiskConfig.sol";
import {IInsuranceController} from "../interfaces/IInsuranceController.sol";
import {ILiquidationEngine} from "../interfaces/ILiquidationEngine.sol";

/// @title LiquidationEngine
/// @notice Evaluates maintenance margin breaches and executes position liquidation settlement.
contract LiquidationEngine is ILiquidationEngine {
    address public immutable positionManager;
    address public immutable oracleAdapter;
    address public immutable riskConfig;
    address public immutable insuranceController;
    mapping(bytes32 graceKey => uint256 expiry) private _gracePeriodExpiry;

    /// @notice Creates liquidation engine with protocol module dependencies.
    /// @param positionManager_ PositionManager address.
    /// @param oracleAdapter_ OracleAdapter address.
    /// @param riskConfig_ RiskConfig address.
    /// @param insuranceController_ InsuranceController address (can be zero if disabled).
    constructor(address positionManager_, address oracleAdapter_, address riskConfig_, address insuranceController_) {
        if (positionManager_ == address(0) || oracleAdapter_ == address(0) || riskConfig_ == address(0)) {
            revert Errors.InvalidAddress();
        }
        positionManager = positionManager_;
        oracleAdapter = oracleAdapter_;
        riskConfig = riskConfig_;
        insuranceController = insuranceController_;
    }

    /// @notice Checks whether a user position is currently liquidatable.
    /// @param user Position owner.
    /// @param marketId Market identifier.
    /// @return liquidatable True when maintenance margin is breached.
    function isLiquidatable(address user, bytes32 marketId) external view override returns (bool liquidatable) {
        Types.Position memory position = IPositionManager(positionManager).getPosition(user, marketId);
        if (position.status != Types.PositionStatus.Open) return false;

        uint256 markPriceX18 = IOracleAdapter(oracleAdapter).getMarkPrice(marketId);
        Types.MarketConfig memory cfg = IRiskConfig(riskConfig).getMarketConfig(marketId);
        if (!cfg.isActive) revert Errors.InvalidMarket();

        if (!_isMaintenanceBreached(position, markPriceX18, cfg.maintenanceMarginBps)) return false;
        if (_isGraceProtected(position, _gracePeriodExpiry[_graceKey(user, marketId)])) return false;

        liquidatable = true;
    }

    /// @notice Returns the stored grace period expiry for a user and market pair.
    /// @param user Position owner.
    /// @param marketId Market identifier.
    /// @return expiry Timestamp when liquidation protection expires.
    function getGracePeriodExpiry(address user, bytes32 marketId) external view override returns (uint256 expiry) {
        return _gracePeriodExpiry[_graceKey(user, marketId)];
    }

    /// @notice Executes liquidation for a liquidatable position and settles insurance claim if applicable.
    /// @param user Position owner.
    /// @param marketId Market identifier.
    function liquidate(address user, bytes32 marketId) external override {
        Types.Position memory position = IPositionManager(positionManager).getPosition(user, marketId);
        if (position.status != Types.PositionStatus.Open) revert Errors.InactivePosition();

        uint256 markPriceX18 = IOracleAdapter(oracleAdapter).getMarkPrice(marketId);
        Types.MarketConfig memory cfg = IRiskConfig(riskConfig).getMarketConfig(marketId);
        if (!cfg.isActive) revert Errors.InvalidMarket();
        if (!_isMaintenanceBreached(position, markPriceX18, cfg.maintenanceMarginBps)) {
            _clearGracePeriod(user, marketId, position);
            revert Errors.InvalidLiquidationState();
        }

        bytes32 graceKey = _graceKey(user, marketId);
        uint256 graceExpiry = _gracePeriodExpiry[graceKey];
        if (_isProtectedPosition(position)) {
            if (graceExpiry == 0) {
                graceExpiry = block.timestamp + IRiskConfig(riskConfig).liquidationGracePeriodSeconds();
                _gracePeriodExpiry[graceKey] = graceExpiry;
                emit Events.LiquidationProtectionActivated(position.id, user, marketId, graceExpiry);
                return;
            }
            if (block.timestamp < graceExpiry) revert Errors.GracePeriodActive();
        }

        emit Events.LiquidationTriggered(position.id, msg.sender, markPriceX18);

        uint256 insurancePayout = 0;
        int256 pnl = _calculatePnl(position, markPriceX18);
        if (position.insuranceStatus == Types.InsuranceStatus.Active && insuranceController != address(0) && pnl < 0) {
            uint256 realizedLoss = uint256(-pnl);
            insurancePayout = IInsuranceController(insuranceController).processLiquidationClaim(
                position.id, user, realizedLoss, true
            );
        }

        IPositionManager(positionManager).markLiquidated(user, marketId, msg.sender, markPriceX18);
        delete _gracePeriodExpiry[graceKey];
        emit Events.LiquidationCompleted(position.id, msg.sender, pnl, insurancePayout);
    }

    /// @notice Refreshes stored protection state after margin top-ups.
    /// @dev Clears the grace window once the position is back above maintenance margin.
    /// @param user Position owner.
    /// @param marketId Market identifier.
    function onMarginUpdated(address user, bytes32 marketId) external override {
        if (msg.sender != positionManager) revert Errors.Unauthorized();

        Types.Position memory position = IPositionManager(positionManager).getPosition(user, marketId);
        if (position.status != Types.PositionStatus.Open) {
            delete _gracePeriodExpiry[_graceKey(user, marketId)];
            return;
        }

        uint256 graceExpiry = _gracePeriodExpiry[_graceKey(user, marketId)];
        if (graceExpiry == 0) return;

        Types.MarketConfig memory cfg = IRiskConfig(riskConfig).getMarketConfig(marketId);
        if (!cfg.isActive) revert Errors.InvalidMarket();
        uint256 markPriceX18 = IOracleAdapter(oracleAdapter).getMarkPrice(marketId);

        if (!_isMaintenanceBreached(position, markPriceX18, cfg.maintenanceMarginBps)) {
            _clearGracePeriod(user, marketId, position);
        }
    }

    /// @notice Computes whether maintenance margin requirement is breached for a position.
    /// @param position Position snapshot.
    /// @param markPriceX18 Current mark price.
    /// @param maintenanceMarginBps Maintenance margin ratio in bps.
    /// @return breached True if margin after unrealized PnL is below required maintenance margin.
    function isMaintenanceBreached(Types.Position memory position, uint256 markPriceX18, uint256 maintenanceMarginBps)
        external
        pure
        returns (bool breached)
    {
        return _isMaintenanceBreached(position, markPriceX18, maintenanceMarginBps);
    }

    function _isMaintenanceBreached(Types.Position memory position, uint256 markPriceX18, uint256 maintenanceMarginBps)
        internal
        pure
        returns (bool breached)
    {
        int256 pnl = _calculatePnl(position, markPriceX18);
        int256 marginAfterPnl = int256(position.collateralAmount) + pnl;
        uint256 maintenanceRequirement = MathLib.mulBps(position.sizeUsdX18, maintenanceMarginBps);
        return marginAfterPnl <= int256(maintenanceRequirement);
    }

    function _calculatePnl(Types.Position memory position, uint256 markPriceX18) internal pure returns (int256) {
        if (position.entryPriceX18 == 0) return 0;
        uint256 priceDiff =
            position.entryPriceX18 > markPriceX18 ? position.entryPriceX18 - markPriceX18 : markPriceX18 - position.entryPriceX18;
        uint256 pnlAbs = (position.sizeUsdX18 * priceDiff) / position.entryPriceX18;
        bool isProfit = position.isLong ? (markPriceX18 >= position.entryPriceX18) : (markPriceX18 <= position.entryPriceX18);
        return isProfit ? int256(pnlAbs) : -int256(pnlAbs);
    }

    function _isProtectedPosition(Types.Position memory position) internal view returns (bool) {
        return position.insuranceStatus == Types.InsuranceStatus.Active
            && IRiskConfig(riskConfig).liquidationGracePeriodSeconds() != 0;
    }

    function _isGraceProtected(Types.Position memory position, uint256 graceExpiry) internal view returns (bool) {
        return _isProtectedPosition(position) && (graceExpiry == 0 || block.timestamp < graceExpiry);
    }

    function _graceKey(address user, bytes32 marketId) internal pure returns (bytes32) {
        return keccak256(abi.encode(user, marketId));
    }

    function _clearGracePeriod(address user, bytes32 marketId, Types.Position memory position) internal {
        bytes32 graceKey = _graceKey(user, marketId);
        if (_gracePeriodExpiry[graceKey] == 0) return;
        delete _gracePeriodExpiry[graceKey];
        emit Events.LiquidationProtectionReleased(position.id, user, marketId);
    }
}
