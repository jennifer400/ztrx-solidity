// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {InsuranceController} from "../contracts/core/InsuranceController.sol";
import {IInsuranceController} from "../contracts/interfaces/IInsuranceController.sol";
import {RiskConfig} from "../contracts/core/RiskConfig.sol";
import {RiskVault} from "../contracts/core/RiskVault.sol";
import {Types} from "../contracts/libraries/Types.sol";
import {Errors} from "../contracts/libraries/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface Vm {
    function prank(address) external;
    function expectRevert(bytes calldata) external;
    function expectRevert(bytes4) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 privateKey) external returns (address);
}

contract InsuranceControllerTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "InsuranceQuote(address user,bytes32 marketId,bool side,uint256 leverageX18,uint256 sizeUsdX18,uint256 premiumBps,uint256 coverageRatioBps,bytes32 riskControlsHash,uint256 expiry,uint256 nonce,bytes32 modelVersion)"
    );
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("ZTRX_INSURANCE");
    bytes32 private constant VERSION_HASH = keccak256("1");

    uint256 private signerPk;
    address private signer;

    MockERC20 private token;
    RiskConfig private config;
    RiskVault private vault;
    InsuranceController private insurance;

    address private owner = address(this);
    address private authorizedModule = address(0xAAA1);
    address private user = address(0xA11CE);
    address private recipient = address(0xCA1A);
    bytes32 private marketId = keccak256("ETH-PERP");
    bytes32 private modelVersion = keccak256("model-v1");

    function setUp() public {
        signerPk = 0xA11CEBEEF;
        signer = vm.addr(signerPk);

        token = new MockERC20("Mock USDC", "mUSDC", 6);
        config = new RiskConfig(owner, signer, 5_000, 2_000, 8_000, 120);
        vault = new RiskVault(owner, address(token), address(config));
        insurance = new InsuranceController(owner, address(config), address(vault), address(token));

        insurance.setAuthorizedCaller(authorizedModule, true);
        vault.setInsuranceController(address(insurance));
        vault.setPremiumCaller(address(insurance), true);

        token.mint(owner, 10_000_000e6);
        token.approve(address(vault), type(uint256).max);
        vault.fundVault(1_000_000e6);

        token.mint(user, 1_000_000e6);
        vm.prank(user);
        token.approve(address(insurance), type(uint256).max);
    }

    function testValidQuoteAccepted() public {
        (IInsuranceController.SignedInsuranceQuote memory q, bytes memory sig) = _signedQuote(user, 1, 2_000e6, 2_000, 3_000);
        vm.prank(authorizedModule);
        insurance.registerCoverage(1, q, sig);

        InsuranceController.CoverageSnapshot memory c = insurance.getCoverage(1);
        _assertEq(uint256(uint8(c.status)), uint256(uint8(Types.InsuranceStatus.Active)));
        _assertEq(c.user, user);
        _assertEq(c.coverageRatioBps, 3_000);
    }

    function testExpiredQuoteRejected() public {
        (IInsuranceController.SignedInsuranceQuote memory q, bytes memory sig) = _signedQuote(user, 2, 2_000e6, 2_000, 3_000);
        q.expiry = block.timestamp - 1;
        sig = _signQuote(q);

        vm.prank(authorizedModule);
        vm.expectRevert(Errors.QuoteExpired.selector);
        insurance.registerCoverage(2, q, sig);
    }

    function testReplayedQuoteRejected() public {
        (IInsuranceController.SignedInsuranceQuote memory q, bytes memory sig) = _signedQuote(user, 3, 2_000e6, 2_000, 3_000);

        vm.prank(authorizedModule);
        insurance.registerCoverage(3, q, sig);

        vm.prank(authorizedModule);
        vm.expectRevert(Errors.QuoteAlreadyUsed.selector);
        insurance.registerCoverage(4, q, sig);
    }

    function testCoverageCapEnforced() public {
        config.setMaxCoverageRatioBps(3_500);
        (IInsuranceController.SignedInsuranceQuote memory q, bytes memory sig) = _signedQuote(user, 5, 2_000e6, 2_000, 4_000);

        vm.prank(authorizedModule);
        vm.expectRevert(Errors.InvalidCoverageRatio.selector);
        insurance.registerCoverage(5, q, sig);
    }

    function testPremiumDeductedOnlyOnProfitableClose() public {
        (IInsuranceController.SignedInsuranceQuote memory q1, bytes memory sig1) =
            _signedQuote(user, 6, 2_000e6, 1_000, 2_500);
        vm.prank(authorizedModule);
        insurance.registerCoverage(6, q1, sig1);

        uint256 beforeAssets = vault.totalAssets();
        vm.prank(authorizedModule);
        uint256 premium = insurance.settlePremiumOnProfit(6, user, 1_000e6);
        _assertEq(premium, 100e6);
        _assertEq(vault.totalAssets(), beforeAssets + 100e6);

        (IInsuranceController.SignedInsuranceQuote memory q2, bytes memory sig2) =
            _signedQuote(user, 7, 2_000e6, 1_000, 2_500);
        vm.prank(authorizedModule);
        insurance.registerCoverage(7, q2, sig2);

        beforeAssets = vault.totalAssets();
        vm.prank(authorizedModule);
        premium = insurance.settlePremiumOnProfit(7, user, 0);
        _assertEq(premium, 0);
        _assertEq(vault.totalAssets(), beforeAssets);
    }

    function testClaimPaidOnlyForActiveEligibleLiquidatedPosition() public {
        (IInsuranceController.SignedInsuranceQuote memory q, bytes memory sig) = _signedQuote(user, 8, 2_000e6, 1_000, 2_000);
        vm.prank(authorizedModule);
        insurance.registerCoverage(8, q, sig);

        vm.prank(authorizedModule);
        vm.expectRevert(Errors.InvalidLiquidationState.selector);
        insurance.processLiquidationClaim(8, recipient, 500e6, false);

        uint256 before = token.balanceOf(recipient);
        vm.prank(authorizedModule);
        uint256 paid = insurance.processLiquidationClaim(8, recipient, 500e6, true);
        _assertEq(paid, 100e6); // 20% coverage of 500
        _assertEq(token.balanceOf(recipient), before + 100e6);

        vm.prank(authorizedModule);
        vm.expectRevert(Errors.InsuranceNotActive.selector);
        insurance.processLiquidationClaim(8, recipient, 500e6, true);
    }

    function _signedQuote(address qUser, uint256 nonce, uint256 sizeUsd, uint256 premiumBps, uint256 coverageBps)
        internal
        
        returns (IInsuranceController.SignedInsuranceQuote memory q, bytes memory sig)
    {
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
            expiry: block.timestamp + 1 days,
            nonce: nonce,
            modelVersion: modelVersion
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
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(insurance))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _assertEq(uint256 a, uint256 b) internal pure {
        assert(a == b);
    }

    function _assertEq(address a, address b) internal pure {
        assert(a == b);
    }
}
