// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PositionManager} from "../contracts/core/PositionManager.sol";
import {MarginVault} from "../contracts/core/MarginVault.sol";
import {RiskConfig} from "../contracts/core/RiskConfig.sol";
import {RiskVault} from "../contracts/core/RiskVault.sol";
import {InsuranceController} from "../contracts/core/InsuranceController.sol";
import {IInsuranceController} from "../contracts/interfaces/IInsuranceController.sol";
import {Types} from "../contracts/libraries/Types.sol";
import {Errors} from "../contracts/libraries/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface Vm {
    function prank(address) external;
    function expectRevert(bytes4) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 privateKey) external returns (address);
    function assume(bool) external;
    function warp(uint256) external;
}

contract ProtocolFuzzTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "InsuranceQuote(address user,bytes32 marketId,bool side,uint256 leverageX18,uint256 sizeUsdX18,uint256 premiumBps,uint256 coverageRatioBps,bytes32 riskControlsHash,uint256 expiry,uint256 nonce,bytes32 modelVersion)"
    );
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("ZTRX_INSURANCE");
    bytes32 private constant VERSION_HASH = keccak256("1");
    uint256 private constant BPS_DIVISOR = 10_000;

    MockERC20 private token;
    MarginVault private marginVault;
    RiskConfig private riskConfig;
    PositionManager private positionManager;
    RiskVault private riskVault;
    InsuranceController private insurance;

    uint256 private signerPk;
    address private signer;
    address private user = address(0xA11CE);
    bytes32 private marketId = keccak256("ETH-PERP");

    function setUp() public {
        signerPk = 0xA11CEBEEF;
        signer = vm.addr(signerPk);

        token = new MockERC20("Mock USDC", "mUSDC", 6);
        marginVault = new MarginVault(address(this), address(token));
        riskConfig = new RiskConfig(address(this), signer, 5_000, 2_000, 8_000, 100);
        positionManager = new PositionManager(address(this), address(marginVault), address(riskConfig));
        riskVault = new RiskVault(address(this), address(token), address(riskConfig));
        insurance = new InsuranceController(address(this), address(riskConfig), address(riskVault), address(token));

        marginVault.setAuthorizedModule(address(positionManager), true);
        positionManager.setRelayer(address(this), true);

        Types.MarketConfig memory m = Types.MarketConfig({
            isActive: true,
            oracle: address(0x1111),
            collateralToken: address(token),
            maxLeverageX18: 20e18,
            maintenanceMarginBps: 800,
            liquidationPenaltyBps: 100,
            maxOpenInterestUsdX18: 100_000_000e18
        });
        riskConfig.setMarketConfig(marketId, m);

        riskVault.setInsuranceController(address(insurance));
        riskVault.setPremiumCaller(address(insurance), true);
        insurance.setAuthorizedCaller(address(this), true);

        token.mint(address(this), 1_000_000_000e6);
        token.approve(address(riskVault), type(uint256).max);
        token.approve(address(insurance), type(uint256).max);
        riskVault.fundVault(500_000_000e6);

        token.mint(user, 1_000_000_000e6);
        vm.prank(user);
        token.approve(address(marginVault), type(uint256).max);
        vm.prank(user);
        token.approve(address(insurance), type(uint256).max);
        vm.prank(user);
        marginVault.deposit(100_000_000e6);
    }

    function testFuzz_LeverageBounds(uint256 leverageX18) public {
        leverageX18 = leverageX18 % 40e18;

        PositionManager.OpenPositionParams memory p = PositionManager.OpenPositionParams({
            owner: user,
            marketId: marketId,
            isLong: true,
            sizeUsdX18: 100_000e18,
            entryPriceX18: 2_000e18,
            leverageX18: leverageX18,
            margin: 10_000e6,
            insuranceTermId: bytes32(0)
        });

        if (leverageX18 == 0 || leverageX18 > 20e18) {
            vm.expectRevert(Errors.InvalidLeverage.selector);
            positionManager.openPosition(p);
            return;
        }

        positionManager.openPosition(p);
        Types.Position memory pos = positionManager.getPosition(user, marketId);
        assert(pos.leverageX18 == leverageX18);
    }

    function testFuzz_PremiumSettlementOnProfit(uint16 premiumBpsRaw, uint96 realizedProfitRaw) public {
        uint256 premiumBps = uint256(premiumBpsRaw) % BPS_DIVISOR;
        uint256 realizedProfit = uint256(realizedProfitRaw) % 1_000_000e6;
        uint256 positionId = 1;

        (IInsuranceController.SignedInsuranceQuote memory quote, bytes memory sig) =
            _signedQuote(user, positionId, 2_000_000e6, premiumBps, 2_500, block.timestamp + 1 days);
        insurance.registerCoverage(positionId, quote, sig);

        uint256 beforeAssets = riskVault.totalAssets();
        uint256 charged = insurance.settlePremiumOnProfit(positionId, user, realizedProfit);
        uint256 expected = (realizedProfit * premiumBps) / BPS_DIVISOR;

        assert(charged == expected);
        assert(riskVault.totalAssets() == beforeAssets + expected);
    }

    function testFuzz_ClaimPayoutCaps(uint16 coverageRaw, uint96 sizeRaw, uint96 lossRaw) public {
        uint256 coverage = uint256(coverageRaw) % 5_001;
        vm.assume(coverage > 0);
        uint256 sizeUsd = (uint256(sizeRaw) % 50_000_000e6) + 1e6;
        uint256 realizedLoss = (uint256(lossRaw) % sizeUsd) + 1;
        vm.assume((realizedLoss * coverage) / BPS_DIVISOR > 0);
        uint256 positionId = 2;

        (IInsuranceController.SignedInsuranceQuote memory quote, bytes memory sig) =
            _signedQuote(user, positionId, sizeUsd, 500, coverage, block.timestamp + 1 days);
        insurance.registerCoverage(positionId, quote, sig);

        InsuranceController.CoverageSnapshot memory snap = insurance.getCoverage(positionId);
        uint256 reserve = snap.reservedAmount;
        uint256 expected = ((realizedLoss * coverage) / BPS_DIVISOR);
        if (expected > reserve) expected = reserve;

        uint256 balBefore = token.balanceOf(user);
        uint256 paid = insurance.processLiquidationClaim(positionId, user, realizedLoss, true);
        assert(paid == expected);
        assert(token.balanceOf(user) == balBefore + expected);
    }

    function testFuzz_ReserveReleaseAccounting(uint96 reserveRaw) public {
        uint256 available = riskVault.getAvailableCapacity();
        vm.assume(available > 0);
        uint256 amount = (uint256(reserveRaw) % available) + 1;
        uint256 positionId = 100;

        uint256 beforeReserved = riskVault.totalReserved();
        insuranceCallReserve(positionId, amount);
        assert(riskVault.totalReserved() == beforeReserved + amount);
        assert(riskVault.getReservedAmount(positionId) == amount);

        insuranceCallRelease(positionId);
        assert(riskVault.totalReserved() == beforeReserved);
        assert(riskVault.getReservedAmount(positionId) == 0);
    }

    function testFuzz_QuoteExpiryAndNonceReplayProtection(bool expiredFirst, uint256 nonceRaw) public {
        uint256 nonce = (nonceRaw % 1_000_000) + 1;
        uint256 expiry = expiredFirst ? block.timestamp - 1 : block.timestamp + 1 days;
        uint256 positionId = 3;

        (IInsuranceController.SignedInsuranceQuote memory quote, bytes memory sig) =
            _signedQuote(user, nonce, 3_000_000e6, 1000, 2000, expiry);

        if (expiredFirst) {
            vm.expectRevert(Errors.QuoteExpired.selector);
            insurance.registerCoverage(positionId, quote, sig);
            return;
        }

        insurance.registerCoverage(positionId, quote, sig);

        vm.expectRevert(Errors.QuoteAlreadyUsed.selector);
        insurance.registerCoverage(positionId + 1, quote, sig);
    }

    function insuranceCallReserve(uint256 positionId, uint256 amount) internal {
        vm.prank(address(insurance));
        riskVault.reserveCapacity(positionId, amount);
    }

    function insuranceCallRelease(uint256 positionId) internal {
        vm.prank(address(insurance));
        riskVault.releaseCapacity(positionId);
    }

    function _signedQuote(
        address qUser,
        uint256 nonce,
        uint256 sizeUsd,
        uint256 premiumBps,
        uint256 coverageBps,
        uint256 expiry
    ) internal returns (IInsuranceController.SignedInsuranceQuote memory q, bytes memory sig) {
        q = IInsuranceController.SignedInsuranceQuote({
            user: qUser,
            marketId: marketId,
            side: true,
            leverageX18: 10e18,
            sizeUsdX18: sizeUsd,
            premiumBps: premiumBps,
            coverageRatioBps: coverageBps,
            maxInsurableAmount: sizeUsd * 2,
            minHoldingTime: 0,
            cooldownSeconds: 0,
            activationDelay: 0,
            fullActivationDelay: 0,
            userTier: 1,
            marketTier: 1,
            expiry: expiry,
            nonce: nonce,
            modelVersion: keccak256("model-v1")
        });
        sig = _signQuote(q);
    }

    function _signQuote(IInsuranceController.SignedInsuranceQuote memory q) internal returns (bytes memory sig) {
        bytes32 riskControlsHash = keccak256(
            abi.encode(
                q.maxInsurableAmount,
                q.minHoldingTime,
                q.cooldownSeconds,
                q.activationDelay,
                q.fullActivationDelay,
                q.userTier,
                q.marketTier
            )
        );
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
                riskControlsHash,
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
