// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FeeRouter} from "../contracts/core/FeeRouter.sol";
import {RiskConfig} from "../contracts/core/RiskConfig.sol";
import {RiskVault} from "../contracts/core/RiskVault.sol";
import {ZTRXNFT} from "../contracts/core/ZTRXNFT.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Errors} from "../contracts/libraries/Errors.sol";

interface Vm {
    function prank(address) external;
    function expectRevert(bytes calldata) external;
    function expectRevert(bytes4) external;
}

contract FeeRouterTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MockERC20 private token;
    RiskConfig private riskConfig;
    RiskVault private riskVault;
    FeeRouter private feeRouter;
    ZTRXNFT private nft;

    address private owner = address(this);
    address private quoteSigner = address(0xBEEF);
    address private treasury = address(0x7EA5);
    address private module = address(0xA11CE);
    address private attacker = address(0xBAD);
    address private trader = address(0xB0B);

    function setUp() public {
        token = new MockERC20("Mock USD", "mUSD", 6);
        riskConfig = new RiskConfig(owner, quoteSigner, 5_000, 2_500, 8_000, 100);
        riskVault = new RiskVault(owner, address(token), address(riskConfig));
        feeRouter = new FeeRouter(owner, address(token), address(riskVault), address(riskConfig), treasury);
        nft = new ZTRXNFT(owner, "ipfs://ztrx/", ".json");

        feeRouter.setAuthorizedCaller(module, true);
        feeRouter.setBenefitNFT(address(nft));
        riskVault.setPremiumCaller(address(feeRouter), true);

        token.mint(module, 1_000_000e6);
        vm.prank(module);
        token.approve(address(feeRouter), type(uint256).max);

        token.mint(trader, 1_000_000e6);
        vm.prank(trader);
        token.approve(address(feeRouter), type(uint256).max);
    }

    function testCorrectSplit() public {
        uint256 vaultBefore = riskVault.totalAssets();
        uint256 treasuryBefore = token.balanceOf(treasury);

        vm.prank(module);
        feeRouter.routePremium(module, 1_000e6);

        // treasury bps = 2500 => 25%
        _assertEq(token.balanceOf(treasury), treasuryBefore + 250e6);
        _assertEq(riskVault.totalAssets(), vaultBefore + 750e6);
        _assertEq(feeRouter.totalPremiumRouted(), 1_000e6);
        _assertEq(feeRouter.totalSentToTreasury(), 250e6);
        _assertEq(feeRouter.totalSentToRiskVault(), 750e6);
        _assertEq(feeRouter.getUnroutedBalance(), 0);
    }

    function testUnauthorizedCallerRejected() public {
        vm.prank(attacker);
        vm.expectRevert(Errors.Unauthorized.selector);
        feeRouter.routePremium(module, 100e6);
    }

    function testZeroAmountHandledSafely() public {
        vm.prank(module);
        vm.expectRevert(Errors.ZeroAmount.selector);
        feeRouter.routePremium(module, 0);

        vm.prank(module);
        vm.expectRevert(Errors.ZeroAmount.selector);
        feeRouter.routeProtocolFee(module, 0);
    }

    function testProtocolFeeDiscountUsesNftBenefits() public {
        ZTRXNFT.BenefitConfig memory config_ = ZTRXNFT.BenefitConfig({
            tradingFeeDiscountBps: 2_000,
            tokenAirdropBonusBps: 200,
            insurancePremiumDiscountBps: 0,
            liquidationProtectionBoostBps: 0,
            tradingCompetitionBoostBps: 500,
            lpYieldBoostBps: 0,
            lpExitCooldownReductionBps: 0,
            partnerWhitelistEligible: true,
            priorityAccessEligible: true
        });
        nft.setThemeBenefits(ZTRXNFT.Theme.Oracle, config_);
        nft.adminMint(trader, 1_950);

        (uint256 previewAmount, uint256 discountBps) = feeRouter.previewDiscountedProtocolFee(trader, 1_000e6);
        _assertEq(previewAmount, 800e6);
        _assertEq(discountBps, 2_000);

        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 vaultBefore = riskVault.totalAssets();

        vm.prank(module);
        uint256 charged = feeRouter.routeProtocolFeeWithBenefits(trader, trader, 1_000e6);

        _assertEq(charged, 800e6);
        _assertEq(token.balanceOf(treasury), treasuryBefore + 200e6);
        _assertEq(riskVault.totalAssets(), vaultBefore + 600e6);
        _assertEq(feeRouter.totalProtocolFeesRouted(), 800e6);
    }

    function _assertEq(uint256 a, uint256 b) internal pure {
        assert(a == b);
    }
}
