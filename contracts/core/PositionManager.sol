// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "../vendor/openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "../vendor/openzeppelin/contracts/access/Ownable2Step.sol";
import {Types} from "../libraries/Types.sol";
import {Errors} from "../libraries/Errors.sol";
import {Events} from "../libraries/Events.sol";
import {IMarginVault} from "../interfaces/IMarginVault.sol";
import {IRiskConfig} from "../interfaces/IRiskConfig.sol";
import {IInsuranceController} from "../interfaces/IInsuranceController.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";

/// @title PositionManager
/// @notice Stores and manages position lifecycle state for isolated-margin perpetual positions.
/// @dev One active position per user per market in MVP.
contract PositionManager is Ownable2Step, IPositionManager {
    error PositionAlreadyOpen();
    error InvalidSize();

    uint256 private constant ONE_X18 = 1e18;

    struct OpenPositionParams {
        address owner;
        bytes32 marketId;
        bool isLong;
        uint256 sizeUsdX18;
        uint256 entryPriceX18;
        uint256 leverageX18;
        uint256 margin;
        bytes32 insuranceTermId;
    }

    struct IncreasePositionParams {
        address owner;
        bytes32 marketId;
        uint256 sizeDeltaUsdX18;
        uint256 executionPriceX18;
        uint256 additionalMargin;
    }

    struct ReducePositionParams {
        address owner;
        bytes32 marketId;
        uint256 sizeDeltaUsdX18;
        uint256 executionPriceX18;
    }

    struct ClosePositionParams {
        address owner;
        bytes32 marketId;
        uint256 executionPriceX18;
    }

    uint256 public nextPositionId;
    address public immutable marginVault;
    address public immutable riskConfig;
    address public insuranceController;

    mapping(address relayer => bool isAuthorized) public authorizedRelayer;
    mapping(address user => mapping(bytes32 marketId => Types.Position position)) private _positions;

    event RelayerUpdated(address indexed relayer, bool isAuthorized);
    event InsuranceControllerUpdated(address indexed previousController, address indexed newController);

    /// @notice Deploys PositionManager with owner and module dependencies.
    /// @param initialOwner Governance owner.
    /// @param marginVault_ MarginVault address for margin lock/unlock operations.
    /// @param riskConfig_ RiskConfig address for market leverage checks.
    constructor(address initialOwner, address marginVault_, address riskConfig_) Ownable(initialOwner) {
        if (marginVault_ == address(0) || riskConfig_ == address(0)) revert Errors.InvalidAddress();
        marginVault = marginVault_;
        riskConfig = riskConfig_;
    }

    modifier onlyRelayer() {
        if (!authorizedRelayer[msg.sender]) revert Errors.Unauthorized();
        _;
    }

    /// @notice Sets relayer authorization for off-chain execution settlement.
    /// @param relayer Relayer address.
    /// @param isAuthorized True to authorize, false to revoke.
    function setRelayer(address relayer, bool isAuthorized) external onlyOwner {
        if (relayer == address(0)) revert Errors.InvalidAddress();
        authorizedRelayer[relayer] = isAuthorized;
        emit RelayerUpdated(relayer, isAuthorized);
    }

    /// @notice Sets insurance controller used for optional position insurance hooks.
    /// @param newInsuranceController Insurance controller address.
    function setInsuranceController(address newInsuranceController) external onlyOwner {
        address previous = insuranceController;
        insuranceController = newInsuranceController;
        emit InsuranceControllerUpdated(previous, newInsuranceController);
    }

    /// @notice Opens a new isolated position for a user and market.
    /// @dev Reverts if user already has an active position in the same market.
    /// @param params Open position parameters settled by authorized relayer.
    function openPosition(OpenPositionParams calldata params) external onlyRelayer {
        if (params.owner == address(0)) revert Errors.InvalidAddress();
        if (params.marketId == bytes32(0)) revert Errors.InvalidMarket();
        if (params.margin == 0 || params.entryPriceX18 == 0) revert Errors.ZeroAmount();
        if (params.sizeUsdX18 == 0) revert InvalidSize();

        Types.Position storage existing = _positions[params.owner][params.marketId];
        if (existing.status == Types.PositionStatus.Open) revert PositionAlreadyOpen();

        Types.MarketConfig memory market = _getValidatedMarket(params.marketId);
        _validateLeverage(params.leverageX18, market.maxLeverageX18);

        IMarginVault(marginVault).lockMargin(params.owner, params.margin);

        uint256 positionId = ++nextPositionId;
        Types.InsuranceStatus insuranceStatus = Types.InsuranceStatus.None;
        if (params.insuranceTermId != bytes32(0) && insuranceController != address(0)) {
            bool activated = IInsuranceController(insuranceController).onPositionOpened(
                params.owner, params.marketId, positionId, params.insuranceTermId
            );
            if (activated) insuranceStatus = Types.InsuranceStatus.Active;
        }

        _positions[params.owner][params.marketId] = Types.Position({
            id: positionId,
            trader: params.owner,
            marketId: params.marketId,
            collateralToken: market.collateralToken,
            collateralAmount: params.margin,
            sizeUsdX18: params.sizeUsdX18,
            entryPriceX18: params.entryPriceX18,
            leverageX18: params.leverageX18,
            isLong: params.isLong,
            status: Types.PositionStatus.Open,
            insuranceStatus: insuranceStatus,
            openedAt: uint64(block.timestamp),
            closedAt: 0,
            insuranceTermId: params.insuranceTermId
        });

        emit Events.PositionOpened(
            positionId,
            params.owner,
            params.marketId,
            params.sizeUsdX18,
            params.margin,
            params.entryPriceX18,
            params.isLong
        );
    }

    /// @notice Increases size and optional margin of an existing open position.
    /// @param params Increase parameters settled by authorized relayer.
    function increasePosition(IncreasePositionParams calldata params) external onlyRelayer {
        Types.Position storage position = _getOpenPosition(params.owner, params.marketId);
        if (params.sizeDeltaUsdX18 == 0 || params.executionPriceX18 == 0) revert Errors.ZeroAmount();

        if (params.additionalMargin > 0) {
            IMarginVault(marginVault).lockMargin(params.owner, params.additionalMargin);
            position.collateralAmount += params.additionalMargin;
        }

        uint256 previousSize = position.sizeUsdX18;
        uint256 newSize = previousSize + params.sizeDeltaUsdX18;

        position.entryPriceX18 =
            ((position.entryPriceX18 * previousSize) + (params.executionPriceX18 * params.sizeDeltaUsdX18)) / newSize;
        position.sizeUsdX18 = newSize;
        position.leverageX18 = _calculateLeverageX18(newSize, position.collateralAmount);

        Types.MarketConfig memory market = _getValidatedMarket(params.marketId);
        _validateLeverage(position.leverageX18, market.maxLeverageX18);

        emit Events.PositionIncreased(position.id, position.sizeUsdX18, params.additionalMargin);
    }

    /// @notice Reduces part of an open position and unlocks proportional margin.
    /// @param params Reduce parameters settled by authorized relayer.
    function reducePosition(ReducePositionParams calldata params) external onlyRelayer {
        Types.Position storage position = _getOpenPosition(params.owner, params.marketId);
        if (params.sizeDeltaUsdX18 == 0 || params.executionPriceX18 == 0) revert Errors.ZeroAmount();
        if (params.sizeDeltaUsdX18 >= position.sizeUsdX18) revert InvalidSize();

        int256 realizedPnl = _calculatePnl(position.isLong, params.sizeDeltaUsdX18, position.entryPriceX18, params.executionPriceX18);
        uint256 marginToUnlock = (position.collateralAmount * params.sizeDeltaUsdX18) / position.sizeUsdX18;

        position.sizeUsdX18 -= params.sizeDeltaUsdX18;
        position.collateralAmount -= marginToUnlock;
        position.leverageX18 = _calculateLeverageX18(position.sizeUsdX18, position.collateralAmount);

        IMarginVault(marginVault).unlockMargin(params.owner, marginToUnlock);
        emit Events.PositionReduced(position.id, params.sizeDeltaUsdX18, realizedPnl);
    }

    /// @notice Closes an open position and unlocks all remaining isolated margin.
    /// @param params Close parameters settled by authorized relayer.
    function closePosition(ClosePositionParams calldata params) external onlyRelayer {
        Types.Position storage position = _getOpenPosition(params.owner, params.marketId);
        if (params.executionPriceX18 == 0) revert Errors.ZeroAmount();

        int256 realizedPnl =
            _calculatePnl(position.isLong, position.sizeUsdX18, position.entryPriceX18, params.executionPriceX18);
        uint256 marginToUnlock = position.collateralAmount;

        if (position.insuranceStatus == Types.InsuranceStatus.Active && insuranceController != address(0)) {
            IInsuranceController(insuranceController).onPositionClosed(
                params.owner, params.marketId, position.id, position.insuranceTermId
            );
            position.insuranceStatus = Types.InsuranceStatus.Settled;
        }

        position.sizeUsdX18 = 0;
        position.collateralAmount = 0;
        position.leverageX18 = 0;
        position.status = Types.PositionStatus.Closed;
        position.closedAt = uint64(block.timestamp);

        IMarginVault(marginVault).unlockMargin(params.owner, marginToUnlock);
        emit Events.PositionClosed(position.id, realizedPnl, params.executionPriceX18);
    }

    /// @notice Marks an open position as liquidated.
    /// @param user Position owner.
    /// @param marketId Market identifier.
    /// @param liquidator Account that executed liquidation.
    /// @param executionPriceX18 Liquidation execution price.
    function markLiquidated(address user, bytes32 marketId, address liquidator, uint256 executionPriceX18)
        external
        onlyRelayer
    {
        Types.Position storage position = _getOpenPosition(user, marketId);
        if (liquidator == address(0) || executionPriceX18 == 0) revert Errors.InvalidLiquidationState();

        emit Events.LiquidationTriggered(position.id, liquidator, executionPriceX18);

        int256 realizedPnl =
            _calculatePnl(position.isLong, position.sizeUsdX18, position.entryPriceX18, executionPriceX18);
        uint256 marginToUnlock = position.collateralAmount;

        if (position.insuranceStatus == Types.InsuranceStatus.Active && insuranceController != address(0)) {
            IInsuranceController(insuranceController).onPositionLiquidated(
                user, marketId, position.id, position.insuranceTermId
            );
            position.insuranceStatus = Types.InsuranceStatus.Settled;
        }

        position.sizeUsdX18 = 0;
        position.collateralAmount = 0;
        position.leverageX18 = 0;
        position.status = Types.PositionStatus.Liquidated;
        position.closedAt = uint64(block.timestamp);

        IMarginVault(marginVault).unlockMargin(user, marginToUnlock);
        emit Events.LiquidationCompleted(position.id, liquidator, realizedPnl, 0);
    }

    /// @notice Returns the latest authoritative position state for a user and market.
    /// @param user Position owner.
    /// @param marketId Market identifier.
    /// @return position Position snapshot.
    function getPosition(address user, bytes32 marketId) external view override returns (Types.Position memory position) {
        return _positions[user][marketId];
    }

    function _getOpenPosition(address user, bytes32 marketId) internal view returns (Types.Position storage position) {
        if (user == address(0) || marketId == bytes32(0)) revert Errors.InvalidMarket();
        position = _positions[user][marketId];
        if (position.status != Types.PositionStatus.Open) revert Errors.InactivePosition();
    }

    function _getValidatedMarket(bytes32 marketId) internal view returns (Types.MarketConfig memory market) {
        market = IRiskConfig(riskConfig).getMarketConfig(marketId);
        if (!market.isActive) revert Errors.InvalidMarket();
    }

    function _validateLeverage(uint256 leverageX18, uint256 maxLeverageX18) internal pure {
        if (leverageX18 == 0 || leverageX18 > maxLeverageX18) revert Errors.InvalidLeverage();
    }

    function _calculateLeverageX18(uint256 sizeUsdX18, uint256 margin) internal pure returns (uint256) {
        if (margin == 0) return 0;
        return (sizeUsdX18 * ONE_X18) / margin;
    }

    function _calculatePnl(bool isLong, uint256 sizeUsdX18, uint256 entryPriceX18, uint256 exitPriceX18)
        internal
        pure
        returns (int256)
    {
        if (entryPriceX18 == 0) return 0;

        uint256 priceDiff = entryPriceX18 > exitPriceX18 ? entryPriceX18 - exitPriceX18 : exitPriceX18 - entryPriceX18;
        uint256 pnlAbs = (sizeUsdX18 * priceDiff) / entryPriceX18;

        bool isProfit = isLong ? (exitPriceX18 >= entryPriceX18) : (exitPriceX18 <= entryPriceX18);
        return isProfit ? int256(pnlAbs) : -int256(pnlAbs);
    }
}
