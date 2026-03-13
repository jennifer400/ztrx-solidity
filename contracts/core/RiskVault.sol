// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "../vendor/openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "../vendor/openzeppelin/contracts/access/Ownable2Step.sol";
import {Errors} from "../libraries/Errors.sol";
import {Events} from "../libraries/Events.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {IRiskVault} from "../interfaces/IRiskVault.sol";
import {IRiskConfig} from "../interfaces/IRiskConfig.sol";
import {IZTRXNFTBenefits} from "../interfaces/IZTRXNFTBenefits.sol";

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
    address public benefitNFT;

    uint256 public totalAssets;
    uint256 public totalReserved;
    uint256 public totalShares;
    uint256 public baseExitCooldownSeconds;
    mapping(uint256 positionId => uint256 amount) public reservedByPosition;
    mapping(address provider => uint256 shares) public shareBalanceOf;
    mapping(address provider => uint256 principal) public principalBalanceOf;
    mapping(address provider => uint256 unlockTimestamp) public lpUnlockTime;
    mapping(address caller => bool isAuthorized) public authorizedPremiumCaller;

    event InsuranceControllerUpdated(address indexed previousController, address indexed newController);
    event PremiumCallerUpdated(address indexed caller, bool isAuthorized);
    event BenefitNFTUpdated(address indexed previousBenefitNFT, address indexed newBenefitNFT);
    event BaseExitCooldownUpdated(uint256 previousCooldown, uint256 newCooldown);

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

    /// @notice Sets NFT contract used for LP boost lookup.
    function setBenefitNFT(address newBenefitNFT) external onlyOwner {
        address previous = benefitNFT;
        benefitNFT = newBenefitNFT;
        emit BenefitNFTUpdated(previous, newBenefitNFT);
    }

    /// @notice Sets base cooldown applied to LP withdrawals and yield claims.
    function setBaseExitCooldown(uint256 newCooldown) external onlyOwner {
        uint256 previous = baseExitCooldownSeconds;
        baseExitCooldownSeconds = newCooldown;
        emit BaseExitCooldownUpdated(previous, newCooldown);
    }

    /// @notice Funds the insurance vault with collateral.
    /// @param amount Token amount to transfer into the vault.
    function fundVault(uint256 amount) external override {
        if (amount == 0) revert Errors.ZeroAmount();
        _safeTransferFrom(collateralToken, msg.sender, address(this), amount);
        totalAssets += amount;
        emit Events.VaultFunded(msg.sender, collateralToken, amount, totalAssets);
    }

    /// @notice Adds LP liquidity and mints proportional vault shares.
    /// @param amount Asset amount deposited by LP.
    /// @return sharesMinted Newly minted LP shares.
    function depositLiquidity(uint256 amount) external override returns (uint256 sharesMinted) {
        if (amount == 0) revert Errors.ZeroAmount();

        uint256 baseSharesMinted = _previewDeposit(amount, totalAssets, totalShares);
        sharesMinted = _applyLpYieldBoost(msg.sender, baseSharesMinted);
        if (sharesMinted == 0) revert Errors.ZeroAmount();

        _safeTransferFrom(collateralToken, msg.sender, address(this), amount);

        totalAssets += amount;
        totalShares += sharesMinted;
        shareBalanceOf[msg.sender] += sharesMinted;
        principalBalanceOf[msg.sender] += amount;
        _refreshUnlockTime(msg.sender);

        emit Events.VaultLiquidityDeposited(
            msg.sender, collateralToken, amount, sharesMinted, totalAssets, totalShares
        );
    }

    /// @notice Redeems LP shares for currently withdrawable assets.
    /// @param shares Share amount burned.
    /// @return assetsReturned Asset amount transferred to LP.
    function redeemLiquidity(uint256 shares) external override returns (uint256 assetsReturned) {
        if (shares == 0) revert Errors.ZeroAmount();

        uint256 providerShares = shareBalanceOf[msg.sender];
        if (providerShares < shares) revert Errors.InsufficientBalance();
        if (block.timestamp < lpUnlockTime[msg.sender]) revert Errors.CooldownActive();

        assetsReturned = _previewRedeem(shares, totalAssets, totalShares);
        if (assetsReturned == 0) revert Errors.ZeroAmount();
        if (assetsReturned > _availableLiquidity()) revert Errors.VaultCapacityExceeded();

        uint256 principalReduction = _proRataPrincipal(msg.sender, shares, providerShares);
        shareBalanceOf[msg.sender] = providerShares - shares;
        principalBalanceOf[msg.sender] -= principalReduction;
        totalShares -= shares;
        totalAssets -= assetsReturned;

        _safeTransfer(collateralToken, msg.sender, assetsReturned);

        emit Events.VaultLiquidityWithdrawn(
            msg.sender, collateralToken, assetsReturned, shares, totalAssets, totalShares
        );
    }

    /// @notice Claims LP profit only, without reducing tracked principal.
    /// @param amount Requested asset amount from accrued yield.
    /// @return assetsClaimed Final asset amount transferred.
    /// @return sharesBurned Share amount burned to realize that yield.
    function claimYield(uint256 amount) external override returns (uint256 assetsClaimed, uint256 sharesBurned) {
        if (amount == 0) revert Errors.ZeroAmount();

        uint256 providerShares = shareBalanceOf[msg.sender];
        if (providerShares == 0) revert Errors.InsufficientBalance();
        if (block.timestamp < lpUnlockTime[msg.sender]) revert Errors.CooldownActive();

        uint256 claimable = _claimableYield(msg.sender, providerShares);
        if (claimable == 0) revert Errors.InsufficientBalance();

        assetsClaimed = amount < claimable ? amount : claimable;
        if (assetsClaimed > _availableLiquidity()) revert Errors.VaultCapacityExceeded();

        sharesBurned = _sharesForAssetsRoundUp(assetsClaimed, totalAssets, totalShares);
        if (sharesBurned == 0 || sharesBurned > providerShares) revert Errors.InsufficientBalance();

        assetsClaimed = _previewRedeem(sharesBurned, totalAssets, totalShares);
        if (assetsClaimed > claimable) revert Errors.InvalidLiquidationState();
        if (assetsClaimed > _availableLiquidity()) revert Errors.VaultCapacityExceeded();

        shareBalanceOf[msg.sender] = providerShares - sharesBurned;
        totalShares -= sharesBurned;
        totalAssets -= assetsClaimed;

        _safeTransfer(collateralToken, msg.sender, assetsClaimed);

        emit Events.VaultYieldClaimed(
            msg.sender,
            collateralToken,
            assetsClaimed,
            sharesBurned,
            principalBalanceOf[msg.sender],
            totalAssets,
            totalShares
        );
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

    /// @notice Returns assets currently not locked by active coverage reserves.
    function getAvailableLiquidity() external view override returns (uint256) {
        return _availableLiquidity();
    }

    /// @notice Returns share amount that would be minted for a deposit.
    function previewDeposit(uint256 amount) external view override returns (uint256 sharesMinted) {
        return _previewDeposit(amount, totalAssets, totalShares);
    }

    /// @notice Returns asset amount redeemable for a share amount.
    function previewRedeem(uint256 shares) external view override returns (uint256 assetsReturned) {
        return _previewRedeem(shares, totalAssets, totalShares);
    }

    /// @notice Returns current asset value for an LP address.
    function lpAssetValue(address provider) external view override returns (uint256 assetValue) {
        return _previewRedeem(shareBalanceOf[provider], totalAssets, totalShares);
    }

    /// @notice Returns current yield claimable by an LP address.
    function claimableYieldOf(address provider) external view override returns (uint256 yieldAmount) {
        return _claimableYield(provider, shareBalanceOf[provider]);
    }

    function _maxReservableAssets() internal view returns (uint256) {
        uint256 limitBps = IRiskConfig(riskConfig).vaultUtilizationLimitBps();
        return MathLib.mulBps(totalAssets, limitBps);
    }

    function _availableLiquidity() internal view returns (uint256) {
        return totalAssets > totalReserved ? totalAssets - totalReserved : 0;
    }

    function _previewDeposit(uint256 amount, uint256 assets, uint256 sharesSupply) internal pure returns (uint256) {
        if (amount == 0) return 0;
        if (sharesSupply == 0 || assets == 0) {
            return amount;
        }
        return (amount * sharesSupply) / assets;
    }

    function _previewRedeem(uint256 shares, uint256 assets, uint256 sharesSupply) internal pure returns (uint256) {
        if (shares == 0 || sharesSupply == 0 || assets == 0) {
            return 0;
        }
        return (shares * assets) / sharesSupply;
    }

    function _claimableYield(address provider, uint256 providerShares) internal view returns (uint256) {
        if (providerShares == 0) return 0;
        uint256 assetValue = _previewRedeem(providerShares, totalAssets, totalShares);
        uint256 principal = principalBalanceOf[provider];
        return assetValue > principal ? assetValue - principal : 0;
    }

    function _proRataPrincipal(address provider, uint256 shares, uint256 providerShares) internal view returns (uint256) {
        uint256 principal = principalBalanceOf[provider];
        if (principal == 0 || providerShares == 0) return 0;
        return (principal * shares) / providerShares;
    }

    function _sharesForAssetsRoundUp(uint256 assets, uint256 assetsPool, uint256 sharesSupply)
        internal
        pure
        returns (uint256)
    {
        if (assets == 0 || assetsPool == 0 || sharesSupply == 0) return 0;
        return ((assets * sharesSupply) + assetsPool - 1) / assetsPool;
    }

    function _applyLpYieldBoost(address provider, uint256 baseSharesMinted) internal view returns (uint256) {
        if (baseSharesMinted == 0 || benefitNFT == address(0)) {
            return baseSharesMinted;
        }

        (uint16 lpYieldBoostBps,) = IZTRXNFTBenefits(benefitNFT).liquidityBenefitAdjustmentsOf(provider);

        if (lpYieldBoostBps == 0) {
            return baseSharesMinted;
        }

        return baseSharesMinted + MathLib.mulBps(baseSharesMinted, lpYieldBoostBps);
    }

    function _refreshUnlockTime(address provider) internal {
        uint256 cooldown = _effectiveExitCooldown(provider);
        if (cooldown == 0) {
            lpUnlockTime[provider] = block.timestamp;
            return;
        }

        uint256 unlockAt = block.timestamp + cooldown;
        if (unlockAt > lpUnlockTime[provider]) {
            lpUnlockTime[provider] = unlockAt;
        }
    }

    function _effectiveExitCooldown(address provider) internal view returns (uint256 cooldown) {
        cooldown = baseExitCooldownSeconds;
        if (cooldown == 0 || benefitNFT == address(0)) {
            return cooldown;
        }

        (, uint16 lpExitCooldownReductionBps) = IZTRXNFTBenefits(benefitNFT).liquidityBenefitAdjustmentsOf(provider);

        if (lpExitCooldownReductionBps == 0) {
            return cooldown;
        }

        uint256 reduction = MathLib.mulBps(cooldown, lpExitCooldownReductionBps);
        return cooldown > reduction ? cooldown - reduction : 0;
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
