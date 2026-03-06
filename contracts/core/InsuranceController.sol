// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "../vendor/openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "../vendor/openzeppelin/contracts/access/Ownable2Step.sol";
import {Types} from "../libraries/Types.sol";
import {Errors} from "../libraries/Errors.sol";
import {Events} from "../libraries/Events.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {IInsuranceController} from "../interfaces/IInsuranceController.sol";
import {IRiskConfig} from "../interfaces/IRiskConfig.sol";
import {IRiskVault} from "../interfaces/IRiskVault.sol";

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title InsuranceController
/// @notice Verifies off-chain insurance quotes and enforces insurance lifecycle for positions.
contract InsuranceController is Ownable2Step, IInsuranceController {
    error TransferFailed();

    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "InsuranceQuote(address user,bytes32 marketId,bool side,uint256 leverageX18,uint256 sizeUsdX18,uint256 premiumBps,uint256 coverageRatioBps,uint256 expiry,uint256 nonce,bytes32 modelVersion)"
    );
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("ZTRX_INSURANCE");
    bytes32 internal constant VERSION_HASH = keccak256("1");
    struct CoverageSnapshot {
        address user;
        bytes32 marketId;
        bool side;
        uint256 leverageX18;
        uint256 sizeUsdX18;
        uint256 premiumBps;
        uint256 coverageRatioBps;
        uint256 reservedAmount;
        uint256 quoteExpiry;
        uint256 quoteNonce;
        bytes32 modelVersion;
        bytes32 quoteHash;
        Types.InsuranceStatus status;
        bool premiumSettled;
    }

    address public immutable riskConfig;
    address public immutable riskVault;
    address public immutable collateralToken;

    mapping(address caller => bool isAuthorized) public authorizedCaller;
    mapping(uint256 positionId => CoverageSnapshot coverage) private _coverageByPosition;
    mapping(bytes32 quoteHash => bool used) public usedQuotes;

    event AuthorizedCallerUpdated(address indexed caller, bool isAuthorized);

    /// @notice Deploys InsuranceController.
    /// @param initialOwner Governance owner.
    /// @param riskConfig_ RiskConfig contract address.
    /// @param riskVault_ RiskVault contract address.
    /// @param collateralToken_ Collateral token used for premium transfers.
    constructor(address initialOwner, address riskConfig_, address riskVault_, address collateralToken_)
        Ownable(initialOwner)
    {
        if (riskConfig_ == address(0) || riskVault_ == address(0) || collateralToken_ == address(0)) {
            revert Errors.InvalidAddress();
        }
        riskConfig = riskConfig_;
        riskVault = riskVault_;
        collateralToken = collateralToken_;
    }

    modifier onlyAuthorizedCaller() {
        if (!authorizedCaller[msg.sender]) revert Errors.Unauthorized();
        _;
    }

    /// @notice Sets whether an address can execute insurance lifecycle actions.
    /// @param caller Caller address.
    /// @param isAuthorized True to authorize, false to revoke.
    function setAuthorizedCaller(address caller, bool isAuthorized) external onlyOwner {
        if (caller == address(0)) revert Errors.InvalidAddress();
        authorizedCaller[caller] = isAuthorized;
        emit AuthorizedCallerUpdated(caller, isAuthorized);
    }

    /// @notice Registers coverage on position open and reserves vault capacity.
    /// @param positionId Position identifier.
    /// @param quote Signed insurance quote payload.
    /// @param signature EIP-712 signature over quote payload.
    function registerCoverage(uint256 positionId, SignedInsuranceQuote calldata quote, bytes calldata signature)
        external
        override
        onlyAuthorizedCaller
    {
        if (positionId == 0) revert Errors.InactivePosition();
        if (quote.expiry < block.timestamp) revert Errors.QuoteExpired();

        bytes32 quoteHash = _quoteHash(quote);
        if (usedQuotes[quoteHash]) revert Errors.QuoteAlreadyUsed();
        if (!verifyQuote(quote, signature)) revert Errors.InvalidSignature();

        uint256 cap = IRiskConfig(riskConfig).maxCoverageRatioBps();
        if (quote.coverageRatioBps > cap) revert Errors.InvalidCoverageRatio();

        uint256 reserveAmount = MathLib.mulBps(quote.sizeUsdX18, quote.coverageRatioBps);
        usedQuotes[quoteHash] = true;

        _coverageByPosition[positionId] = CoverageSnapshot({
            user: quote.user,
            marketId: quote.marketId,
            side: quote.side,
            leverageX18: quote.leverageX18,
            sizeUsdX18: quote.sizeUsdX18,
            premiumBps: quote.premiumBps,
            coverageRatioBps: quote.coverageRatioBps,
            reservedAmount: reserveAmount,
            quoteExpiry: quote.expiry,
            quoteNonce: quote.nonce,
            modelVersion: quote.modelVersion,
            quoteHash: quoteHash,
            status: Types.InsuranceStatus.Active,
            premiumSettled: false
        });

        IRiskVault(riskVault).reserveCapacity(positionId, reserveAmount);
        emit Events.InsuranceActivated(
            positionId, positionId, quoteHash, quote.coverageRatioBps, quote.premiumBps, reserveAmount
        );
    }

    /// @notice Settles premium only when close is profitable.
    /// @param positionId Position identifier.
    /// @param payer Address paying premium token amount.
    /// @param realizedProfit Profit realized on close.
    /// @return premiumCharged Premium transferred to vault.
    function settlePremiumOnProfit(uint256 positionId, address payer, uint256 realizedProfit)
        external
        override
        onlyAuthorizedCaller
        returns (uint256 premiumCharged)
    {
        CoverageSnapshot storage snapshot = _coverageByPosition[positionId];
        if (snapshot.status != Types.InsuranceStatus.Active) revert Errors.InsuranceNotActive();
        if (payer == address(0)) revert Errors.InvalidAddress();
        if (snapshot.premiumSettled) return 0;

        if (realizedProfit > 0) {
            premiumCharged = MathLib.mulBps(realizedProfit, snapshot.premiumBps);
            if (premiumCharged > 0) {
                snapshot.premiumSettled = true;
                _safeTransferFrom(collateralToken, payer, address(this), premiumCharged);
                _safeApprove(collateralToken, riskVault, premiumCharged);
                IRiskVault(riskVault).receivePremium(premiumCharged);
                emit Events.PremiumSettled(positionId, positionId, snapshot.user, collateralToken, premiumCharged);
                return premiumCharged;
            }
        }

        snapshot.premiumSettled = true;
        emit Events.PremiumSettled(positionId, positionId, snapshot.user, collateralToken, premiumCharged);
    }

    /// @notice Processes liquidation claim when insured position is eligible and active.
    /// @param positionId Position identifier.
    /// @param recipient Claim recipient.
    /// @param realizedLoss Loss amount used to compute payout.
    /// @param eligible Whether liquidation is insurance-eligible.
    /// @return claimPaid Amount paid from RiskVault.
    function processLiquidationClaim(uint256 positionId, address recipient, uint256 realizedLoss, bool eligible)
        external
        override
        onlyAuthorizedCaller
        returns (uint256 claimPaid)
    {
        CoverageSnapshot storage snapshot = _coverageByPosition[positionId];
        if (snapshot.status != Types.InsuranceStatus.Active) revert Errors.InsuranceNotActive();
        if (!eligible || recipient == address(0)) revert Errors.InvalidLiquidationState();
        if (realizedLoss == 0) revert Errors.InvalidLiquidationState();

        uint256 maxClaim = MathLib.mulBps(realizedLoss, snapshot.coverageRatioBps);
        claimPaid = maxClaim < snapshot.reservedAmount ? maxClaim : snapshot.reservedAmount;

        snapshot.status = Types.InsuranceStatus.Settled;
        IRiskVault(riskVault).payClaim(positionId, recipient, claimPaid);

        emit Events.ClaimPaid(positionId, positionId, recipient, collateralToken, claimPaid);
    }

    /// @notice Cancels active coverage on normal close and releases reserved capacity.
    /// @param positionId Position identifier.
    function cancelCoverageOnClose(uint256 positionId) external override onlyAuthorizedCaller {
        _cancelCoverage(positionId);
    }

    function _cancelCoverage(uint256 positionId) internal {
        CoverageSnapshot storage snapshot = _coverageByPosition[positionId];
        if (snapshot.status != Types.InsuranceStatus.Active) revert Errors.InsuranceNotActive();
        snapshot.status = Types.InsuranceStatus.Expired;
        IRiskVault(riskVault).releaseCapacity(positionId);
        emit Events.InsuranceCancelled(positionId, positionId);
    }

    /// @notice Verifies quote signature against configured quote signer.
    /// @param quote Quote payload.
    /// @param signature EIP-712 signature.
    /// @return True when signature is valid and signer matches config.
    function verifyQuote(SignedInsuranceQuote calldata quote, bytes calldata signature) public view override returns (bool) {
        if (quote.expiry < block.timestamp) return false;
        if (signature.length != 65) return false;

        bytes32 digest = _hashTypedDataV4(_quoteHash(quote));
        address recovered = _recoverSigner(digest, signature);
        return recovered == IRiskConfig(riskConfig).quoteSigner();
    }

    /// @notice Hook called by PositionManager when a position opens.
    /// @dev Coverage registration is done through `registerCoverage`; this hook only reports current status.
    function onPositionOpened(address, bytes32, uint256 positionId, bytes32)
        external
        view
        override
        onlyAuthorizedCaller
        returns (bool)
    {
        return _coverageByPosition[positionId].status == Types.InsuranceStatus.Active;
    }

    /// @notice Hook called by PositionManager when a position closes.
    /// @param positionId Position identifier.
    function onPositionClosed(address, bytes32, uint256 positionId, bytes32) external override onlyAuthorizedCaller {
        if (_coverageByPosition[positionId].status == Types.InsuranceStatus.Active) {
            _cancelCoverage(positionId);
        }
    }

    /// @notice Hook called by PositionManager when a position is liquidated.
    /// @dev Claim processing is handled by LiquidationEngine through `processLiquidationClaim`.
    function onPositionLiquidated(address, bytes32, uint256 positionId, bytes32) external override onlyAuthorizedCaller {
        if (_coverageByPosition[positionId].status == Types.InsuranceStatus.Active) {
            _coverageByPosition[positionId].status = Types.InsuranceStatus.Settled;
        }
    }

    /// @notice Returns insurance snapshot for a position.
    /// @param positionId Position identifier.
    function getCoverage(uint256 positionId) external view returns (CoverageSnapshot memory) {
        return _coverageByPosition[positionId];
    }

    /// @notice Returns EIP-712 domain separator.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    function _quoteHash(SignedInsuranceQuote calldata quote) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                quote.user,
                quote.marketId,
                quote.side,
                quote.leverageX18,
                quote.sizeUsdX18,
                quote.premiumBps,
                quote.coverageRatioBps,
                quote.expiry,
                quote.nonce,
                quote.modelVersion
            )
        );
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _recoverSigner(bytes32 digest, bytes calldata signature) internal pure returns (address signer) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        signer = ecrecover(digest, v, r, s);
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Minimal.approve.selector, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
