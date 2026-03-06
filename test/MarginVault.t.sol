// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MarginVault} from "../contracts/core/MarginVault.sol";
import {Errors} from "../contracts/libraries/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

interface Vm {
    function prank(address) external;
    function expectRevert(bytes calldata) external;
    function expectRevert(bytes4) external;
}

contract MarginVaultTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MockERC20 private token;
    MarginVault private vault;

    address private owner = address(this);
    address private user = address(0xA11CE);
    address private module = address(0xB0B);
    address private stranger = address(0xBAD);

    function setUp() public {
        token = new MockERC20("Mock USDC", "mUSDC", 6);
        vault = new MarginVault(owner, address(token));
        vault.setAuthorizedModule(module, true);

        token.mint(user, 1_000_000e6);
        vm.prank(user);
        token.approve(address(vault), type(uint256).max);
    }

    function testDepositWithdrawHappyPath() public {
        vm.prank(user);
        vault.deposit(1000e6);

        _assertEq(vault.totalBalance(user), 1000e6);
        _assertEq(vault.availableBalance(user), 1000e6);

        vm.prank(user);
        vault.withdraw(400e6);

        _assertEq(vault.totalBalance(user), 600e6);
        _assertEq(vault.availableBalance(user), 600e6);
        _assertEq(token.balanceOf(user), 1_000_000e6 - 1000e6 + 400e6);
    }

    function testCannotWithdrawLockedFunds() public {
        vm.prank(user);
        vault.deposit(1000e6);

        vm.prank(module);
        vault.lockMargin(user, 700e6);

        vm.prank(user);
        vm.expectRevert(Errors.InsufficientMargin.selector);
        vault.withdraw(400e6);
    }

    function testOnlyAuthorizedModuleCanLockUnlock() public {
        vm.prank(user);
        vault.deposit(1000e6);

        vm.prank(stranger);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.lockMargin(user, 100e6);

        vm.prank(stranger);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.unlockMargin(user, 100e6);

        vm.prank(module);
        vault.lockMargin(user, 300e6);
        vm.prank(module);
        vault.unlockMargin(user, 100e6);
        _assertEq(vault.lockedMargin(user), 200e6);
    }

    function testAvailableBalanceCalculation() public {
        vm.prank(user);
        vault.deposit(1000e6);

        vm.prank(module);
        vault.lockMargin(user, 250e6);
        _assertEq(vault.availableBalance(user), 750e6);

        vm.prank(module);
        vault.unlockMargin(user, 100e6);
        _assertEq(vault.availableBalance(user), 850e6);
    }

    function testEdgeCasesZeroAndRepeatedLocks() public {
        vm.prank(user);
        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.deposit(0);

        vm.prank(user);
        vault.deposit(1000e6);

        vm.prank(module);
        vault.lockMargin(user, 400e6);
        vm.prank(module);
        vault.lockMargin(user, 300e6);
        _assertEq(vault.lockedMargin(user), 700e6);

        vm.prank(module);
        vm.expectRevert(Errors.InsufficientMargin.selector);
        vault.lockMargin(user, 301e6);

        vm.prank(module);
        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.unlockMargin(user, 0);

        vm.prank(user);
        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.withdraw(0);
    }

    function _assertEq(uint256 a, uint256 b) internal pure {
        assert(a == b);
    }
}
