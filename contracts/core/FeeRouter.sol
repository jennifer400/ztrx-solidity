// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "../vendor/openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "../vendor/openzeppelin/contracts/access/Ownable2Step.sol";
import {Errors} from "../libraries/Errors.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {IFeeRouter} from "../interfaces/IFeeRouter.sol";
import {IRiskConfig} from "../interfaces/IRiskConfig.sol";
import {IRiskVault} from "../interfaces/IRiskVault.sol";
import {IZTRXNFTBenefits} from "../interfaces/IZTRXNFTBenefits.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title FeeRouter
/// @notice Routes protocol fee flows between treasury and RiskVault based on RiskConfig split settings.
contract FeeRouter is Ownable2Step, IFeeRouter {
    error TransferFailed();

    uint256 private constant BPS_DIVISOR = 10_000;

    address public immutable collateralToken;
    address public immutable riskVault;
    address public immutable riskConfig;
    address public treasury;
    address public benefitNFT;

    mapping(address caller => bool isAuthorized) public authorizedCaller;

    uint256 public totalPremiumRouted;
    uint256 public totalProtocolFeesRouted;
    uint256 public totalSentToTreasury;
    uint256 public totalSentToRiskVault;

    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event AuthorizedCallerUpdated(address indexed caller, bool isAuthorized);
    event BenefitNFTUpdated(address indexed previousBenefitNFT, address indexed newBenefitNFT);
    event PremiumRouted(
        address indexed caller,
        address indexed payer,
        uint256 amount,
        uint256 treasuryAmount,
        uint256 vaultAmount,
        uint256 treasuryBps
    );
    event ProtocolFeeRouted(
        address indexed caller,
        address indexed payer,
        uint256 amount,
        uint256 treasuryAmount,
        uint256 vaultAmount,
        uint256 treasuryBps
    );

    /// @notice Deploys FeeRouter.
    /// @param initialOwner Governance owner.
    /// @param collateralToken_ ERC20 token used for fee settlement.
    /// @param riskVault_ RiskVault destination.
    /// @param riskConfig_ RiskConfig source for split bps.
    /// @param treasury_ Treasury destination.
    constructor(address initialOwner, address collateralToken_, address riskVault_, address riskConfig_, address treasury_)
        Ownable(initialOwner)
    {
        if (
            initialOwner == address(0) || collateralToken_ == address(0) || riskVault_ == address(0)
                || riskConfig_ == address(0) || treasury_ == address(0)
        ) revert Errors.InvalidAddress();
        collateralToken = collateralToken_;
        riskVault = riskVault_;
        riskConfig = riskConfig_;
        treasury = treasury_;
    }

    modifier onlyAuthorizedCaller() {
        if (!authorizedCaller[msg.sender]) revert Errors.Unauthorized();
        _;
    }

    /// @notice Sets caller authorization for routing functions.
    /// @param caller Address allowed to route fee flows.
    /// @param isAuthorized True to authorize, false to revoke.
    function setAuthorizedCaller(address caller, bool isAuthorized) external onlyOwner {
        if (caller == address(0)) revert Errors.InvalidAddress();
        authorizedCaller[caller] = isAuthorized;
        emit AuthorizedCallerUpdated(caller, isAuthorized);
    }

    /// @notice Updates treasury destination address.
    /// @param newTreasury New treasury receiver.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert Errors.InvalidAddress();
        address previous = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previous, newTreasury);
    }

    function setBenefitNFT(address newBenefitNFT) external onlyOwner {
        address previous = benefitNFT;
        benefitNFT = newBenefitNFT;
        emit BenefitNFTUpdated(previous, newBenefitNFT);
    }

    /// @notice Routes premium income and deposits vault share via `RiskVault.receivePremium`.
    /// @param payer Address that provides token funds.
    /// @param amount Total premium amount to route.
    function routePremium(address payer, uint256 amount) external override onlyAuthorizedCaller {
        (uint256 treasuryAmount, uint256 vaultAmount, uint256 treasuryBps) = _routeFrom(payer, amount);
        totalPremiumRouted += amount;

        if (vaultAmount > 0) {
            _safeApprove(collateralToken, riskVault, vaultAmount);
            IRiskVault(riskVault).receivePremium(vaultAmount);
        }

        emit PremiumRouted(msg.sender, payer, amount, treasuryAmount, vaultAmount, treasuryBps);
    }

    /// @notice Routes realized protocol fees and deposits vault share via `RiskVault.fundVault`.
    /// @param payer Address that provides token funds.
    /// @param amount Total fee amount to route.
    function routeProtocolFee(address payer, uint256 amount) external override onlyAuthorizedCaller {
        (uint256 treasuryAmount, uint256 vaultAmount, uint256 treasuryBps) = _routeFrom(payer, amount);
        totalProtocolFeesRouted += amount;

        if (vaultAmount > 0) {
            _safeApprove(collateralToken, riskVault, vaultAmount);
            IRiskVault(riskVault).fundVault(vaultAmount);
        }

        emit ProtocolFeeRouted(msg.sender, payer, amount, treasuryAmount, vaultAmount, treasuryBps);
    }

    function previewDiscountedProtocolFee(address benefitAccount, uint256 grossAmount)
        external
        view
        returns (uint256 netAmount, uint256 discountBps)
    {
        discountBps = _tradingFeeDiscountBps(benefitAccount);
        netAmount = grossAmount - MathLib.mulBps(grossAmount, discountBps);
    }

    function routeProtocolFeeWithBenefits(address payer, address benefitAccount, uint256 grossAmount)
        external
        onlyAuthorizedCaller
        returns (uint256 chargedAmount)
    {
        if (grossAmount == 0) revert Errors.ZeroAmount();

        uint256 discountBps = _tradingFeeDiscountBps(benefitAccount);
        chargedAmount = grossAmount - MathLib.mulBps(grossAmount, discountBps);

        (uint256 treasuryAmount, uint256 vaultAmount, uint256 treasuryBps) = _routeFrom(payer, chargedAmount);
        totalProtocolFeesRouted += chargedAmount;

        if (vaultAmount > 0) {
            _safeApprove(collateralToken, riskVault, vaultAmount);
            IRiskVault(riskVault).fundVault(vaultAmount);
        }

        emit ProtocolFeeRouted(msg.sender, payer, chargedAmount, treasuryAmount, vaultAmount, treasuryBps);
    }

    /// @notice Returns current unrouted token balance held by FeeRouter.
    function getUnroutedBalance() external view override returns (uint256) {
        return IERC20Minimal(collateralToken).balanceOf(address(this));
    }

    function _routeFrom(address payer, uint256 amount)
        internal
        returns (uint256 treasuryAmount, uint256 vaultAmount, uint256 treasuryBps)
    {
        if (payer == address(0)) revert Errors.InvalidAddress();
        if (amount == 0) revert Errors.ZeroAmount();

        treasuryBps = IRiskConfig(riskConfig).premiumTreasuryBps();
        if (treasuryBps > BPS_DIVISOR) revert Errors.InvalidOracleConfig();

        _safeTransferFrom(collateralToken, payer, address(this), amount);

        treasuryAmount = MathLib.mulBps(amount, treasuryBps);
        vaultAmount = amount - treasuryAmount;

        if (treasuryAmount > 0) {
            _safeTransfer(collateralToken, treasury, treasuryAmount);
            totalSentToTreasury += treasuryAmount;
        }
        if (vaultAmount > 0) {
            totalSentToRiskVault += vaultAmount;
        }
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

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok0, bytes memory data0) =
            token.call(abi.encodeWithSelector(IERC20Minimal.approve.selector, spender, 0));
        if (!ok0 || (data0.length != 0 && !abi.decode(data0, (bool)))) revert TransferFailed();

        (bool ok1, bytes memory data1) =
            token.call(abi.encodeWithSelector(IERC20Minimal.approve.selector, spender, amount));
        if (!ok1 || (data1.length != 0 && !abi.decode(data1, (bool)))) revert TransferFailed();
    }

    function _tradingFeeDiscountBps(address benefitAccount) internal view returns (uint256 discountBps) {
        if (benefitNFT == address(0) || benefitAccount == address(0)) {
            return 0;
        }

        discountBps = IZTRXNFTBenefits(benefitNFT).tradingFeeDiscountOf(benefitAccount);
    }
}
