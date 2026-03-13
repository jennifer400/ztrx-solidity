// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RiskVault} from "../contracts/core/RiskVault.sol";
import {RiskConfig} from "../contracts/core/RiskConfig.sol";
import {ZTRXNFT} from "../contracts/core/ZTRXNFT.sol";
import {Errors} from "../contracts/libraries/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface Vm {
    function prank(address) external;
    function expectRevert(bytes calldata) external;
    function expectRevert(bytes4) external;
    function warp(uint256) external;
}

contract RiskVaultTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MockERC20 private token;
    RiskConfig private config;
    RiskVault private vault;
    ZTRXNFT private nft;

    address private owner = address(this);
    address private quoteSigner = address(0xBEEF);
    address private insuranceController = address(0x1C0);
    address private premiumModule = address(0xFEE);
    address private attacker = address(0xBAD);
    address private claimant = address(0xCA1A);
    address private lp1 = address(0x1111);
    address private lp2 = address(0x2222);

    function setUp() public {
        token = new MockERC20("Mock USDC", "mUSDC", 6);
        config = new RiskConfig(owner, quoteSigner, 3_000, 2_000, 8_000, 100);
        vault = new RiskVault(owner, address(token), address(config));
        nft = new ZTRXNFT(owner, "ipfs://ztrx/", ".json");

        vault.setInsuranceController(insuranceController);
        vault.setPremiumCaller(premiumModule, true);
        vault.setBenefitNFT(address(nft));
        vault.setBaseExitCooldown(1 days);

        token.mint(owner, 10_000e6);
        token.mint(premiumModule, 2_000e6);
        token.mint(lp1, 5_000e6);
        token.mint(lp2, 5_000e6);
        token.approve(address(vault), type(uint256).max);

        vm.prank(premiumModule);
        token.approve(address(vault), type(uint256).max);
        vm.prank(lp1);
        token.approve(address(vault), type(uint256).max);
        vm.prank(lp2);
        token.approve(address(vault), type(uint256).max);
    }

    function testReserveAndReleaseCapacity() public {
        vault.fundVault(1_000e6);

        vm.prank(insuranceController);
        vault.reserveCapacity(1, 500e6);
        _assertEq(vault.totalReserved(), 500e6);
        _assertEq(vault.getReservedAmount(1), 500e6);

        vm.prank(insuranceController);
        vault.releaseCapacity(1);
        _assertEq(vault.totalReserved(), 0);
        _assertEq(vault.getReservedAmount(1), 0);
    }

    function testCannotOverReserve() public {
        vault.fundVault(1_000e6); // utilization 80% -> max reservable 800e6

        vm.prank(insuranceController);
        vm.expectRevert(Errors.VaultCapacityExceeded.selector);
        vault.reserveCapacity(11, 801e6);
    }

    function testPremiumIncreasesAvailableAssets() public {
        vault.fundVault(1_000e6);
        _assertEq(vault.totalAssets(), 1_000e6);

        vm.prank(premiumModule);
        vault.receivePremium(200e6);

        _assertEq(vault.totalAssets(), 1_200e6);
        _assertEq(vault.getAvailableCapacity(), 960e6); // 80% of 1200
    }

    function testClaimReducesAssetsAndClearsReserve() public {
        vault.fundVault(1_000e6);

        vm.prank(insuranceController);
        vault.reserveCapacity(77, 400e6);

        uint256 before = token.balanceOf(claimant);
        vm.prank(insuranceController);
        vault.payClaim(77, claimant, 250e6);

        _assertEq(vault.totalAssets(), 750e6);
        _assertEq(vault.totalReserved(), 0);
        _assertEq(vault.getReservedAmount(77), 0);
        _assertEq(token.balanceOf(claimant), before + 250e6);
    }

    function testUnauthorizedCallerRejected() public {
        vault.fundVault(1_000e6);

        vm.prank(attacker);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.reserveCapacity(1, 100e6);

        vm.prank(attacker);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.releaseCapacity(1);

        vm.prank(attacker);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.receivePremium(10e6);

        vm.prank(attacker);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.payClaim(1, claimant, 10e6);
    }

    function testLpDepositMintsSharesOneToOneInitially() public {
        vm.prank(lp1);
        uint256 shares = vault.depositLiquidity(1_000e6);

        _assertEq(shares, 1_000e6);
        _assertEq(vault.totalAssets(), 1_000e6);
        _assertEq(vault.totalShares(), 1_000e6);
        _assertEq(vault.shareBalanceOf(lp1), 1_000e6);
        _assertEq(vault.principalBalanceOf(lp1), 1_000e6);
    }

    function testNftLpYieldBoostMintsExtraShares() public {
        _grantLpBenefits(lp1, 2_000, 0);

        vm.prank(lp1);
        uint256 shares = vault.depositLiquidity(1_000e6);

        _assertEq(shares, 1_200e6);
        _assertEq(vault.shareBalanceOf(lp1), 1_200e6);
    }

    function testPremiumAccruesToLpSharePrice() public {
        vm.prank(lp1);
        vault.depositLiquidity(1_000e6);

        vm.prank(premiumModule);
        vault.receivePremium(200e6);

        _assertEq(vault.totalAssets(), 1_200e6);
        _assertEq(vault.previewRedeem(1_000e6), 1_200e6);
    }

    function testMultipleLpProvidersReceiveProRataShares() public {
        vm.prank(lp1);
        vault.depositLiquidity(1_000e6);

        vm.prank(premiumModule);
        vault.receivePremium(200e6);

        vm.prank(lp2);
        uint256 minted = vault.depositLiquidity(600e6);

        _assertEq(minted, 500e6);
        _assertEq(vault.totalShares(), 1_500e6);
        _assertEq(vault.shareBalanceOf(lp2), 500e6);
    }

    function testLpCanRedeemWithProfit() public {
        vm.prank(lp1);
        vault.depositLiquidity(1_000e6);

        vm.prank(premiumModule);
        vault.receivePremium(300e6);
        vm.warp(block.timestamp + 1 days);

        uint256 before = token.balanceOf(lp1);
        vm.prank(lp1);
        uint256 assets = vault.redeemLiquidity(1_000e6);

        _assertEq(assets, 1_300e6);
        _assertEq(token.balanceOf(lp1), before + 1_300e6);
        _assertEq(vault.totalAssets(), 0);
        _assertEq(vault.totalShares(), 0);
        _assertEq(vault.principalBalanceOf(lp1), 0);
    }

    function testLpRedemptionCannotUseReservedAssets() public {
        vm.prank(lp1);
        vault.depositLiquidity(1_000e6);
        vm.warp(block.timestamp + 1 days);

        vm.prank(insuranceController);
        vault.reserveCapacity(1, 700e6);

        vm.prank(lp1);
        vm.expectRevert(Errors.VaultCapacityExceeded.selector);
        vault.redeemLiquidity(500e6);

        _assertEq(vault.getAvailableLiquidity(), 300e6);
    }

    function testClaimableYieldTracksProfitAbovePrincipal() public {
        vm.prank(lp1);
        vault.depositLiquidity(1_000e6);

        vm.prank(premiumModule);
        vault.receivePremium(300e6);

        _assertEq(vault.principalBalanceOf(lp1), 1_000e6);
        _assertEq(vault.lpAssetValue(lp1), 1_300e6);
        _assertEq(vault.claimableYieldOf(lp1), 300e6);
    }

    function testLpCanClaimYieldWithoutReducingPrincipal() public {
        vm.prank(lp1);
        vault.depositLiquidity(1_000e6);

        vm.prank(premiumModule);
        vault.receivePremium(300e6);
        vm.warp(block.timestamp + 1 days);

        uint256 before = token.balanceOf(lp1);
        vm.prank(lp1);
        (uint256 claimed, uint256 burned) = vault.claimYield(300e6);

        _assertEq(claimed, 300e6);
        assert(burned > 0);
        _assertEq(token.balanceOf(lp1), before + 300e6);
        _assertEq(vault.principalBalanceOf(lp1), 1_000e6);
        _assertEq(vault.claimableYieldOf(lp1), 0);
        _assertEq(vault.lpAssetValue(lp1), 1_000e6);
    }

    function testRedeemReducesPrincipalProRata() public {
        vm.prank(lp1);
        vault.depositLiquidity(1_000e6);

        vm.prank(premiumModule);
        vault.receivePremium(200e6);
        vm.warp(block.timestamp + 1 days);

        vm.prank(lp1);
        vault.redeemLiquidity(500e6);

        _assertEq(vault.principalBalanceOf(lp1), 500e6);
        _assertEq(vault.shareBalanceOf(lp1), 500e6);
    }

    function testExitCooldownBlocksImmediateRedeem() public {
        vm.prank(lp1);
        vault.depositLiquidity(1_000e6);

        vm.prank(lp1);
        vm.expectRevert(Errors.CooldownActive.selector);
        vault.redeemLiquidity(100e6);
    }

    function testNftCooldownReductionAllowsEarlierExit() public {
        _grantLpBenefits(lp1, 0, 5_000);

        vm.prank(lp1);
        vault.depositLiquidity(1_000e6);

        _assertEq(vault.lpUnlockTime(lp1), block.timestamp + 12 hours);

        vm.warp(block.timestamp + 12 hours);
        vm.prank(lp1);
        vault.redeemLiquidity(100e6);
    }

    function _grantLpBenefits(address account, uint16 lpYieldBoostBps, uint16 lpExitCooldownReductionBps) internal {
        ZTRXNFT.BenefitConfig memory config_ = ZTRXNFT.BenefitConfig({
            tradingFeeDiscountBps: 0,
            tokenAirdropBonusBps: 0,
            insurancePremiumDiscountBps: 0,
            liquidationProtectionBoostBps: 0,
            tradingCompetitionBoostBps: 0,
            lpYieldBoostBps: lpYieldBoostBps,
            lpExitCooldownReductionBps: lpExitCooldownReductionBps,
            partnerWhitelistEligible: false,
            priorityAccessEligible: false
        });
        nft.setThemeBenefits(ZTRXNFT.Theme.Oracle, config_);
        nft.adminMint(account, 1_950);
    }

    function _assertEq(uint256 a, uint256 b) internal pure {
        assert(a == b);
    }
}
