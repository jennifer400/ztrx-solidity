// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FeeRouter} from "../contracts/core/FeeRouter.sol";
import {RiskConfig} from "../contracts/core/RiskConfig.sol";
import {RiskVault} from "../contracts/core/RiskVault.sol";
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

    address private owner = address(this);
    address private quoteSigner = address(0xBEEF);
    address private treasury = address(0x7EA5);
    address private module = address(0xA11CE);
    address private attacker = address(0xBAD);

    function setUp() public {
        token = new MockERC20("Mock USD", "mUSD", 6);
        riskConfig = new RiskConfig(owner, quoteSigner, 5_000, 2_500, 8_000, 100);
        riskVault = new RiskVault(owner, address(token), address(riskConfig));
        feeRouter = new FeeRouter(owner, address(token), address(riskVault), address(riskConfig), treasury);

        feeRouter.setAuthorizedCaller(module, true);
        riskVault.setPremiumCaller(address(feeRouter), true);

        token.mint(module, 1_000_000e6);
        vm.prank(module);
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

    function _assertEq(uint256 a, uint256 b) internal pure {
        assert(a == b);
    }
}
