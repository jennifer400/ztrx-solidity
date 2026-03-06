// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RiskConfig} from "../contracts/core/RiskConfig.sol";
import {Types} from "../contracts/libraries/Types.sol";
import {Errors} from "../contracts/libraries/Errors.sol";

interface Vm {
    function prank(address) external;
    function expectRevert(bytes calldata) external;
    function expectRevert(bytes4) external;
}

contract RiskConfigTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes4 private constant OWNABLE_UNAUTHORIZED_ACCOUNT_SELECTOR =
        bytes4(keccak256("OwnableUnauthorizedAccount(address)"));

    RiskConfig private riskConfig;

    address private owner = address(this);
    address private quoteSigner = address(0xBEEF);
    address private alice = address(0xA11CE);
    bytes32 private marketId = keccak256("ETH-USD-PERP");

    function setUp() public {
        riskConfig = new RiskConfig(owner, quoteSigner, 3_000, 2_000, 8_000, 150);
    }

    function testMarketConfigCreateAndUpdate() public {
        Types.MarketConfig memory config = Types.MarketConfig({
            isActive: true,
            oracle: address(0x1001),
            collateralToken: address(0x2001),
            maxLeverageX18: 10e18,
            maintenanceMarginBps: 800,
            liquidationPenaltyBps: 120,
            maxOpenInterestUsdX18: 1_000_000e18
        });

        riskConfig.setMarketConfig(marketId, config);

        Types.MarketConfig memory saved = riskConfig.getMarketConfig(marketId);
        _assertEq(saved.isActive, true);
        _assertEq(saved.oracle, address(0x1001));
        _assertEq(saved.collateralToken, address(0x2001));
        _assertEq(saved.maxLeverageX18, 10e18);
        _assertEq(saved.maintenanceMarginBps, 800);
        _assertEq(saved.liquidationPenaltyBps, 120);
        _assertEq(saved.maxOpenInterestUsdX18, 1_000_000e18);

        config.maxLeverageX18 = 15e18;
        config.isActive = false;
        riskConfig.setMarketConfig(marketId, config);

        saved = riskConfig.getMarketConfig(marketId);
        _assertEq(saved.maxLeverageX18, 15e18);
        _assertEq(saved.isActive, false);
    }

    function testMaxCoverageCannotExceedFiftyPercent() public {
        vm.expectRevert(Errors.InvalidCoverageRatio.selector);
        riskConfig.setMaxCoverageRatioBps(5_001);
    }

    function testInvalidSignerRejected() public {
        vm.expectRevert(RiskConfig.InvalidSigner.selector);
        riskConfig.setQuoteSigner(address(0));
    }

    function testNonOwnerCannotUpdateConfig() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_ACCOUNT_SELECTOR, alice));
        riskConfig.setPremiumTreasuryBps(1_500);
    }

    function _assertEq(uint256 a, uint256 b) internal pure {
        assert(a == b);
    }

    function _assertEq(address a, address b) internal pure {
        assert(a == b);
    }

    function _assertEq(bool a, bool b) internal pure {
        assert(a == b);
    }
}
