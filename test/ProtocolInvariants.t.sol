// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MarginVault} from "../contracts/core/MarginVault.sol";
import {RiskConfig} from "../contracts/core/RiskConfig.sol";
import {RiskVault} from "../contracts/core/RiskVault.sol";
import {InsuranceController} from "../contracts/core/InsuranceController.sol";
import {IInsuranceController} from "../contracts/interfaces/IInsuranceController.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {StdInvariant} from "./utils/StdInvariant.sol";

interface Vm {
    function prank(address) external;
    function addr(uint256 privateKey) external returns (address);
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
}

contract ProtocolInvariantHandler {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "InsuranceQuote(address user,bytes32 marketId,bool side,uint256 leverageX18,uint256 sizeUsdX18,uint256 premiumBps,uint256 coverageRatioBps,uint256 expiry,uint256 nonce,bytes32 modelVersion)"
    );
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("ZTRX_INSURANCE");
    bytes32 private constant VERSION_HASH = keccak256("1");
    uint256 private constant BPS_DIVISOR = 10_000;

    MockERC20 public immutable token;
    MarginVault public immutable marginVault;
    RiskConfig public immutable riskConfig;
    RiskVault public immutable riskVault;
    InsuranceController public immutable insurance;

    uint256 private immutable signerPk;

    address[] private _users;
    uint256[] private _activePositions;

    uint256 public maxCoverageSeen;
    bool public replaySucceeded;
    bool public doubleClaimSucceeded;
    bool public upfrontPremiumCharged;
    uint256 public nextPositionId = 1;

    constructor(
        MockERC20 token_,
        MarginVault marginVault_,
        RiskConfig riskConfig_,
        RiskVault riskVault_,
        InsuranceController insurance_,
        uint256 signerPk_,
        address[] memory users_
    ) {
        token = token_;
        marginVault = marginVault_;
        riskConfig = riskConfig_;
        riskVault = riskVault_;
        insurance = insurance_;
        signerPk = signerPk_;
        _users = users_;
    }

    function userCount() external view returns (uint256) {
        return _users.length;
    }

    function userAt(uint256 i) external view returns (address) {
        return _users[i];
    }

    function actionDeposit(uint8 userIdx, uint96 amountRaw) external {
        address user = _users[uint256(userIdx) % _users.length];
        uint256 amount = (uint256(amountRaw) % 1_000_000e6) + 1;
        vm.prank(user);
        try marginVault.deposit(amount) {} catch {}
    }

    function actionWithdraw(uint8 userIdx, uint96 amountRaw) external {
        address user = _users[uint256(userIdx) % _users.length];
        uint256 available = marginVault.availableBalance(user);
        if (available == 0) return;
        uint256 amount = (uint256(amountRaw) % available) + 1;
        vm.prank(user);
        try marginVault.withdraw(amount) {} catch {}
    }

    function actionLockUnlock(uint8 userIdx, uint96 lockRaw, uint96 unlockRaw) external {
        address user = _users[uint256(userIdx) % _users.length];
        uint256 available = marginVault.availableBalance(user);
        if (available > 0) {
            uint256 lockAmount = (uint256(lockRaw) % available) + 1;
            try marginVault.lockMargin(user, lockAmount) {} catch {}
        }

        uint256 locked = marginVault.lockedMargin(user);
        if (locked > 0) {
            uint256 unlockAmount = (uint256(unlockRaw) % locked) + 1;
            try marginVault.unlockMargin(user, unlockAmount) {} catch {}
        }
    }

    function actionRegisterCoverage(uint8 userIdx, uint16 coverageRatioBps, uint16 premiumBps, uint96 sizeRaw) external {
        address user = _users[uint256(userIdx) % _users.length];
        uint256 positionId = nextPositionId++;

        IInsuranceController.SignedInsuranceQuote memory quote = IInsuranceController.SignedInsuranceQuote({
            user: user,
            marketId: keccak256("ETH-PERP"),
            side: true,
            leverageX18: 10e18,
            sizeUsdX18: (uint256(sizeRaw) % 1_000_000e6) + 1e6,
            premiumBps: uint256(premiumBps) % BPS_DIVISOR,
            coverageRatioBps: uint256(coverageRatioBps) % (BPS_DIVISOR + 1),
            expiry: block.timestamp + 1 days,
            nonce: positionId,
            modelVersion: keccak256("model-v1")
        });

        bytes memory sig = _signQuote(quote);
        uint256 balBefore = token.balanceOf(user);

        (bool ok,) = address(insurance).call(
            abi.encodeWithSelector(IInsuranceController.registerCoverage.selector, positionId, quote, sig)
        );

        if (ok) {
            uint256 balAfter = token.balanceOf(user);
            if (balAfter < balBefore) upfrontPremiumCharged = true;
            if (quote.coverageRatioBps > maxCoverageSeen) maxCoverageSeen = quote.coverageRatioBps;
            _activePositions.push(positionId);
        }

        // Replay same quote must fail.
        (bool replayOk,) = address(insurance).call(
            abi.encodeWithSelector(IInsuranceController.registerCoverage.selector, positionId + 10_000, quote, sig)
        );
        if (replayOk) replaySucceeded = true;
    }

    function actionSettlePremium(uint96 profitRaw) external {
        if (_activePositions.length == 0) return;
        uint256 positionId = _activePositions[0];

        IInsuranceController.SignedInsuranceQuote memory q = insuranceQuoteForPosition(positionId);
        if (q.user == address(0)) return;

        uint256 realizedProfit = uint256(profitRaw) % 50_000e6;
        (bool ok,) = address(insurance).call(
            abi.encodeWithSelector(IInsuranceController.settlePremiumOnProfit.selector, positionId, q.user, realizedProfit)
        );
        ok;
    }

    function actionClaim(uint96 lossRaw) external {
        if (_activePositions.length == 0) return;
        uint256 idx = _activePositions.length - 1;
        uint256 positionId = _activePositions[idx];

        IInsuranceController.SignedInsuranceQuote memory q = insuranceQuoteForPosition(positionId);
        if (q.user == address(0)) return;

        uint256 realizedLoss = (uint256(lossRaw) % 50_000e6) + 1;
        (bool ok,) = address(insurance).call(
            abi.encodeWithSelector(
                IInsuranceController.processLiquidationClaim.selector, positionId, q.user, realizedLoss, true
            )
        );
        if (ok) {
            (bool secondOk,) = address(insurance).call(
                abi.encodeWithSelector(
                    IInsuranceController.processLiquidationClaim.selector, positionId, q.user, realizedLoss, true
                )
            );
            if (secondOk) doubleClaimSucceeded = true;
            _activePositions.pop();
        }
    }

    function actionCancelCoverage() external {
        if (_activePositions.length == 0) return;
        uint256 positionId = _activePositions[_activePositions.length - 1];
        (bool ok,) = address(insurance).call(
            abi.encodeWithSelector(IInsuranceController.cancelCoverageOnClose.selector, positionId)
        );
        if (ok) _activePositions.pop();
    }

    function insuranceQuoteForPosition(uint256 positionId) public view returns (IInsuranceController.SignedInsuranceQuote memory q) {
        InsuranceController.CoverageSnapshot memory c = insurance.getCoverage(positionId);
        q = IInsuranceController.SignedInsuranceQuote({
            user: c.user,
            marketId: c.marketId,
            side: c.side,
            leverageX18: c.leverageX18,
            sizeUsdX18: c.sizeUsdX18,
            premiumBps: c.premiumBps,
            coverageRatioBps: c.coverageRatioBps,
            expiry: c.quoteExpiry,
            nonce: c.quoteNonce,
            modelVersion: c.modelVersion
        });
    }

    function _signQuote(IInsuranceController.SignedInsuranceQuote memory q) internal returns (bytes memory sig) {
        bytes32 structHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                q.user,
                q.marketId,
                q.side,
                q.leverageX18,
                q.sizeUsdX18,
                q.premiumBps,
                q.coverageRatioBps,
                q.expiry,
                q.nonce,
                q.modelVersion
            )
        );
        bytes32 domainSeparator =
            keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(insurance)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        sig = abi.encodePacked(r, s, v);
    }
}

contract ProtocolInvariants is StdInvariant {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MockERC20 private token;
    MarginVault private marginVault;
    RiskConfig private riskConfig;
    RiskVault private riskVault;
    InsuranceController private insurance;
    ProtocolInvariantHandler private handler;

    function setUp() public {
        uint256 signerPk = 0xA11CEBEEF;
        address signer = vm.addr(signerPk);

        token = new MockERC20("Mock USDC", "mUSDC", 6);
        marginVault = new MarginVault(address(this), address(token));
        riskConfig = new RiskConfig(address(this), signer, 5_000, 2_000, 8_000, 100);
        riskVault = new RiskVault(address(this), address(token), address(riskConfig));
        insurance = new InsuranceController(address(this), address(riskConfig), address(riskVault), address(token));

        riskVault.setInsuranceController(address(insurance));
        riskVault.setPremiumCaller(address(insurance), true);

        address[] memory users = new address[](3);
        users[0] = address(0xA11CE);
        users[1] = address(0xB0B);
        users[2] = address(0xCAFE);

        for (uint256 i = 0; i < users.length; i++) {
            token.mint(users[i], 10_000_000e6);
            vm.prank(users[i]);
            token.approve(address(marginVault), type(uint256).max);
            vm.prank(users[i]);
            token.approve(address(insurance), type(uint256).max);
            vm.prank(users[i]);
            marginVault.deposit(1_000_000e6);
        }

        token.mint(address(this), 20_000_000e6);
        token.approve(address(riskVault), type(uint256).max);
        riskVault.fundVault(5_000_000e6);

        handler = new ProtocolInvariantHandler(token, marginVault, riskConfig, riskVault, insurance, signerPk, users);

        marginVault.setAuthorizedModule(address(handler), true);
        insurance.setAuthorizedCaller(address(handler), true);

        targetContract(address(handler));
    }

    function invariant_lockedMarginNeverExceedsTotalBalance() public view {
        uint256 count = handler.userCount();
        for (uint256 i = 0; i < count; i++) {
            address u = handler.userAt(i);
            assert(marginVault.lockedMargin(u) <= marginVault.totalBalance(u));
        }
    }

    function invariant_reservedCapacityWithinAllowedUtilization() public view {
        uint256 maxReservable = (riskVault.totalAssets() * riskConfig.vaultUtilizationLimitBps()) / 10_000;
        assert(riskVault.totalReserved() <= maxReservable);
    }

    function invariant_coverageRatioNeverExceeds50Percent() public view {
        assert(handler.maxCoverageSeen() <= 5_000);
    }

    function invariant_usedInsuranceQuoteCannotReplay() public view {
        assert(!handler.replaySucceeded());
    }

    function invariant_liquidatedPositionCannotBeClaimedTwice() public view {
        assert(!handler.doubleClaimSucceeded());
    }

    function invariant_premiumNeverChargedUpfront() public view {
        assert(!handler.upfrontPremiumCharged());
    }
}
