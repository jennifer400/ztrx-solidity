// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "../vendor/openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "../vendor/openzeppelin/contracts/access/Ownable2Step.sol";
import {Errors} from "../libraries/Errors.sol";
import {Events} from "../libraries/Events.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {IRiskVault} from "../interfaces/IRiskVault.sol";
import {IRiskConfig} from "../interfaces/IRiskConfig.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title RiskVault
/// @notice Protocol insurance reserve that funds claim payouts for eligible liquidations.
/// @dev Uses a single ERC20 collateral token for MVP.
contract RiskVault is Ownable2Step, IRiskVault {
    error TransferFailed();

    address public immutable collateralToken;
    address public insuranceController;
    address public immutable riskConfig;

    uint256 public totalAssets;
    uint256 public totalReserved;
    mapping(uint256 positionId => uint256 amount) public reservedByPosition;
    mapping(address caller => bool isAuthorized) public authorizedPremiumCaller;

    event InsuranceControllerUpdated(address indexed previousController, address indexed newController);
    event PremiumCallerUpdated(address indexed caller, bool isAuthorized);

    /// @notice Deploys vault with owner, collateral token and config source.
    /// @param initialOwner Governance owner.
    /// @param collateralToken_ ERC20 collateral token address.
    /// @param riskConfig_ RiskConfig contract used for utilization limits.
    constructor(address initialOwner, address collateralToken_, address riskConfig_) Ownable(initialOwner) {
        if (collateralToken_ == address(0) || riskConfig_ == address(0)) revert Errors.InvalidAddress();
        collateralToken = collateralToken_;
        riskConfig = riskConfig_;
    }

    modifier onlyInsuranceController() {
        if (msg.sender != insuranceController) revert Errors.Unauthorized();
        _;
    }

    modifier onlyAuthorizedPremiumCaller() {
        if (!authorizedPremiumCaller[msg.sender]) revert Errors.Unauthorized();
        _;
    }

    /// @notice Sets insurance controller address allowed to reserve/release/pay claims.
    /// @param newInsuranceController Insurance controller contract address.
    function setInsuranceController(address newInsuranceController) external onlyOwner {
        if (newInsuranceController == address(0)) revert Errors.InvalidAddress();
        address previous = insuranceController;
        insuranceController = newInsuranceController;
        emit InsuranceControllerUpdated(previous, newInsuranceController);
    }

    /// @notice Sets whether a protocol module can deposit premium income.
    /// @param caller Module address.
    /// @param isAuthorized True to authorize premium deposits.
    function setPremiumCaller(address caller, bool isAuthorized) external onlyOwner {
        if (caller == address(0)) revert Errors.InvalidAddress();
        authorizedPremiumCaller[caller] = isAuthorized;
        emit PremiumCallerUpdated(caller, isAuthorized);
    }

    /// @notice Funds the insurance vault with collateral.
    /// @param amount Token amount to transfer into the vault.
    function fundVault(uint256 amount) external override {
        if (amount == 0) revert Errors.ZeroAmount();
        _safeTransferFrom(collateralToken, msg.sender, address(this), amount);
        totalAssets += amount;
        emit Events.VaultFunded(msg.sender, collateralToken, amount, totalAssets);
    }

    /// @notice Reserves claim capacity for an insured position.
    /// @param positionId Position identifier.
    /// @param amount Capacity amount to reserve.
    function reserveCapacity(uint256 positionId, uint256 amount) external override onlyInsuranceController {
        if (positionId == 0) revert Errors.InactivePosition();
        if (amount == 0) revert Errors.ZeroAmount();
        if (reservedByPosition[positionId] != 0) revert Errors.InvalidLiquidationState();

        uint256 nextReserved = totalReserved + amount;
        if (nextReserved > _maxReservableAssets()) revert Errors.VaultCapacityExceeded();

        reservedByPosition[positionId] = amount;
        totalReserved = nextReserved;
        emit Events.VaultReserved(positionId, amount, totalReserved);
    }

    /// @notice Releases previously reserved capacity for a position.
    /// @param positionId Position identifier.
    function releaseCapacity(uint256 positionId) external override onlyInsuranceController {
        if (positionId == 0) revert Errors.InactivePosition();
        uint256 reserved = reservedByPosition[positionId];
        if (reserved == 0) revert Errors.InsuranceNotActive();

        reservedByPosition[positionId] = 0;
        totalReserved -= reserved;
        emit Events.VaultReserveReleased(positionId, reserved, totalReserved);
    }

    /// @notice Receives premium income sent by authorized protocol modules.
    /// @param amount Premium amount to transfer into vault.
    function receivePremium(uint256 amount) external override onlyAuthorizedPremiumCaller {
        if (amount == 0) revert Errors.ZeroAmount();
        _safeTransferFrom(collateralToken, msg.sender, address(this), amount);
        totalAssets += amount;
        emit Events.VaultPremiumReceived(msg.sender, collateralToken, amount, totalAssets);
    }

    /// @notice Pays liquidation claim to recipient and clears position reserve.
    /// @param positionId Position identifier.
    /// @param recipient Claim beneficiary.
    /// @param amount Claim amount to pay.
    function payClaim(uint256 positionId, address recipient, uint256 amount) external override onlyInsuranceController {
        if (positionId == 0) revert Errors.InactivePosition();
        if (recipient == address(0)) revert Errors.InvalidAddress();
        if (amount == 0) revert Errors.ZeroAmount();

        uint256 reserved = reservedByPosition[positionId];
        if (reserved == 0) revert Errors.InsuranceNotActive();
        if (amount > reserved || amount > totalAssets) revert Errors.VaultCapacityExceeded();

        reservedByPosition[positionId] = 0;
        totalReserved -= reserved;
        totalAssets -= amount;
        _safeTransfer(collateralToken, recipient, amount);

        emit Events.VaultReserveReleased(positionId, reserved, totalReserved);
        emit Events.VaultClaimPaid(positionId, recipient, collateralToken, amount, totalAssets);
    }

    /// @notice Returns currently available reservable capacity under utilization limit.
    function getAvailableCapacity() external view override returns (uint256) {
        uint256 maxReservable = _maxReservableAssets();
        return maxReservable > totalReserved ? maxReservable - totalReserved : 0;
    }

    /// @notice Returns reserved amount for a specific position.
    /// @param positionId Position identifier.
    function getReservedAmount(uint256 positionId) external view override returns (uint256) {
        return reservedByPosition[positionId];
    }

    function _maxReservableAssets() internal view returns (uint256) {
        uint256 limitBps = IRiskConfig(riskConfig).vaultUtilizationLimitBps();
        return MathLib.mulBps(totalAssets, limitBps);
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
