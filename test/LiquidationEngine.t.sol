// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "../contracts/libraries/Types.sol";
import {Errors} from "../contracts/libraries/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {MockInsuranceModule} from "./mocks/MockInsuranceModule.sol";
import {MarginVault} from "../contracts/core/MarginVault.sol";
import {RiskConfig} from "../contracts/core/RiskConfig.sol";
import {OracleAdapter} from "../contracts/core/OracleAdapter.sol";
import {PositionManager} from "../contracts/core/PositionManager.sol";
import {LiquidationEngine} from "../contracts/core/LiquidationEngine.sol";

interface Vm {
    function prank(address) external;
    function expectRevert(bytes calldata) external;
    function expectRevert(bytes4) external;
    function warp(uint256) external;
}

contract LiquidationEngineTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MockERC20 private token;
    MockPriceFeed private markFeed;
    MockPriceFeed private indexFeed;
    MockInsuranceModule private insurance;

    MarginVault private vault;
    RiskConfig private riskConfig;
    OracleAdapter private oracle;
    PositionManager private positionManager;
    LiquidationEngine private liquidationEngine;

    address private owner = address(this);
    address private quoteSigner = address(0xBEEF);
    address private user = address(0xA11CE);
    bytes32 private marketId = keccak256("ETH-PERP");

    function setUp() public {
        token = new MockERC20("Mock USD", "mUSD", 18);
        markFeed = new MockPriceFeed(8);
        indexFeed = new MockPriceFeed(8);
        insurance = new MockInsuranceModule();

        vault = new MarginVault(owner, address(token));
        riskConfig = new RiskConfig(owner, quoteSigner, 5_000, 2_000, 8_000, 100);
        oracle = new OracleAdapter(owner);
        positionManager = new PositionManager(owner, address(vault), address(riskConfig));
        liquidationEngine = new LiquidationEngine(address(positionManager), address(oracle), address(riskConfig), address(insurance));

        vault.setAuthorizedModule(address(positionManager), true);
        positionManager.setRelayer(owner, true);
        positionManager.setRelayer(address(liquidationEngine), true);
        positionManager.setInsuranceController(address(insurance));

        Types.MarketConfig memory cfg = Types.MarketConfig({
            isActive: true,
            oracle: address(oracle),
            collateralToken: address(token),
            maxLeverageX18: 20e18,
            maintenanceMarginBps: 1_000,
            liquidationPenaltyBps: 100,
            maxOpenInterestUsdX18: 1_000_000e18
        });
        riskConfig.setMarketConfig(marketId, cfg);

        markFeed.setAnswer(100e8, block.timestamp);
        indexFeed.setAnswer(100e8, block.timestamp);
        oracle.setMarketFeeds(marketId, address(markFeed), address(indexFeed), 300, 500, 1e18, 1_000_000e18);

        token.mint(user, 10_000e18);
        vm.prank(user);
        token.approve(address(vault), type(uint256).max);
        vm.prank(user);
        vault.deposit(1_000e18);
    }

    function testLiquidatableThreshold() public {
        _openPosition(true, bytes32(0));

        markFeed.setAnswer(95e8, block.timestamp);
        indexFeed.setAnswer(95e8, block.timestamp);
        bool liquidatable = liquidationEngine.isLiquidatable(user, marketId);
        _assertEq(liquidatable, false);

        markFeed.setAnswer(85e8, block.timestamp);
        indexFeed.setAnswer(85e8, block.timestamp);
        liquidatable = liquidationEngine.isLiquidatable(user, marketId);
        _assertEq(liquidatable, true);
    }

    function testNonLiquidatablePositionRejected() public {
        _openPosition(true, bytes32(0));
        markFeed.setAnswer(98e8, block.timestamp);
        indexFeed.setAnswer(98e8, block.timestamp);

        vm.expectRevert(Errors.InvalidLiquidationState.selector);
        liquidationEngine.liquidate(user, marketId);
    }

    function testLiquidationTriggersInsuranceClaimPathWhenActive() public {
        insurance.setClaimToReturn(50e18);
        _openPosition(true, bytes32("insured"));

        markFeed.setAnswer(80e8, block.timestamp);
        indexFeed.setAnswer(80e8, block.timestamp);

        liquidationEngine.liquidate(user, marketId);

        _assertEq(insurance.processCallCount(), 1);
        _assertEq(insurance.lastRecipient(), user);
        Types.Position memory p = positionManager.getPosition(user, marketId);
        _assertEq(uint256(uint8(p.status)), uint256(uint8(Types.PositionStatus.Liquidated)));
    }

    function testLiquidationWithoutInsuranceDoesNotCallPayout() public {
        _openPosition(true, bytes32(0));
        markFeed.setAnswer(80e8, block.timestamp);
        indexFeed.setAnswer(80e8, block.timestamp);

        liquidationEngine.liquidate(user, marketId);
        _assertEq(insurance.processCallCount(), 0);
    }

    function testEdgeCaseStaleOracleRejected() public {
        _openPosition(true, bytes32(0));
        vm.warp(block.timestamp + 301);

        vm.expectRevert(Errors.StalePrice.selector);
        liquidationEngine.isLiquidatable(user, marketId);
    }

    function _openPosition(bool isLong, bytes32 insuranceTermId) internal {
        PositionManager.OpenPositionParams memory p = PositionManager.OpenPositionParams({
            owner: user,
            marketId: marketId,
            isLong: isLong,
            sizeUsdX18: 1_000e18,
            entryPriceX18: 100e18,
            leverageX18: 5e18,
            margin: 200e18,
            insuranceTermId: insuranceTermId
        });
        positionManager.openPosition(p);
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
