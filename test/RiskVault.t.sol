// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RiskVault} from "../contracts/core/RiskVault.sol";
import {RiskConfig} from "../contracts/core/RiskConfig.sol";
import {Errors} from "../contracts/libraries/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface Vm {
    function prank(address) external;
    function expectRevert(bytes calldata) external;
    function expectRevert(bytes4) external;
}

contract RiskVaultTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MockERC20 private token;
    RiskConfig private config;
    RiskVault private vault;

    address private owner = address(this);
    address private quoteSigner = address(0xBEEF);
    address private insuranceController = address(0x1C0);
    address private premiumModule = address(0xFEE);
    address private attacker = address(0xBAD);
    address private claimant = address(0xCA1A);

    function setUp() public {
        token = new MockERC20("Mock USDC", "mUSDC", 6);
        config = new RiskConfig(owner, quoteSigner, 3_000, 2_000, 8_000, 100);
        vault = new RiskVault(owner, address(token), address(config));

        vault.setInsuranceController(insuranceController);
        vault.setPremiumCaller(premiumModule, true);

        token.mint(owner, 10_000e6);
        token.mint(premiumModule, 2_000e6);
        token.approve(address(vault), type(uint256).max);

        vm.prank(premiumModule);
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

    function _assertEq(uint256 a, uint256 b) internal pure {
        assert(a == b);
    }
}
