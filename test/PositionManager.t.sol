// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PositionManager} from "../contracts/core/PositionManager.sol";
import {MarginVault} from "../contracts/core/MarginVault.sol";
import {RiskConfig} from "../contracts/core/RiskConfig.sol";
import {LiquidationEngine} from "../contracts/core/LiquidationEngine.sol";
import {OracleAdapter} from "../contracts/core/OracleAdapter.sol";
import {Types} from "../contracts/libraries/Types.sol";
import {Errors} from "../contracts/libraries/Errors.sol";
import {Events} from "../contracts/libraries/Events.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockInsuranceModule} from "./mocks/MockInsuranceModule.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";

interface Vm {
    function prank(address) external;
    function expectRevert() external;
    function expectRevert(bytes calldata) external;
    function expectRevert(bytes4) external;
    function expectEmit(bool, bool, bool, bool) external;
    function warp(uint256) external;
}

contract PositionManagerTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MockERC20 private token;
    MarginVault private vault;
    RiskConfig private config;
    PositionManager private manager;
    MockInsuranceModule private insurance;
    MockPriceFeed private markFeed;
    MockPriceFeed private indexFeed;
    OracleAdapter private oracle;
    LiquidationEngine private liquidationEngine;

    address private owner = address(this);
    address private quoteSigner = address(0xBEEF);
    address private relayer = address(0xAAAA);
    address private nonRelayer = address(0xDEAD);
    address private nonOwner = address(0xBADD);
    address private user = address(0xA11CE);
    bytes32 private marketId = keccak256("ETH-PERP");

    function setUp() public {
        token = new MockERC20("Mock USDC", "mUSDC", 6);
        vault = new MarginVault(owner, address(token));
        config = new RiskConfig(owner, quoteSigner, 3_000, 2_000, 8_000, 100);
        manager = new PositionManager(owner, address(vault), address(config));
        insurance = new MockInsuranceModule();
        markFeed = new MockPriceFeed(8);
        indexFeed = new MockPriceFeed(8);
        oracle = new OracleAdapter(owner);
        liquidationEngine = new LiquidationEngine(address(manager), address(oracle), address(config), address(insurance));

        vault.setAuthorizedModule(address(manager), true);
        manager.setRelayer(relayer, true);
        manager.setRelayer(address(liquidationEngine), true);
        manager.setLiquidationEngine(address(liquidationEngine));

        Types.MarketConfig memory m = Types.MarketConfig({
            isActive: true,
            oracle: address(0x1111),
            collateralToken: address(token),
            maxLeverageX18: 20e18,
            maintenanceMarginBps: 800,
            liquidationPenaltyBps: 100,
            maxOpenInterestUsdX18: 100_000_000e18
        });
        config.setMarketConfig(marketId, m);
        markFeed.setAnswer(2_000e8, block.timestamp);
        indexFeed.setAnswer(2_000e8, block.timestamp);
        oracle.setMarketFeeds(marketId, address(markFeed), address(indexFeed), 300, 500, 1e18, 10_000_000e18);

        token.mint(user, 1_000_000e6);
        vm.prank(user);
        token.approve(address(vault), type(uint256).max);
        vm.prank(user);
        vault.deposit(100_000e6);
    }

    function testOpenPositionHappyPathAndEvent() public {
        PositionManager.OpenPositionParams memory p = _defaultOpenParams();

        vm.expectEmit(true, true, true, true);
        emit Events.PositionOpened(1, user, marketId, p.sizeUsdX18, p.margin, p.entryPriceX18, p.isLong);
        vm.prank(relayer);
        manager.openPosition(p);

        Types.Position memory pos = manager.getPosition(user, marketId);
        _assertEq(pos.id, 1);
        _assertEq(pos.trader, user);
        _assertEq(pos.marketId, marketId);
        _assertEq(pos.collateralAmount, 10_000e6);
        _assertEq(pos.sizeUsdX18, 100_000e18);
        _assertEq(pos.entryPriceX18, 2_000e18);
        _assertEq(uint256(uint8(pos.status)), uint256(uint8(Types.PositionStatus.Open)));
        _assertEq(uint256(uint8(pos.insuranceStatus)), uint256(uint8(Types.InsuranceStatus.None)));
        _assertEq(vault.lockedMargin(user), 10_000e6);
        _assertEq(manager.nextPositionId(), 1);
    }

    function testOpenPositionAuthorizationFailure() public {
        PositionManager.OpenPositionParams memory p = _defaultOpenParams();
        vm.prank(nonRelayer);
        vm.expectRevert(Errors.Unauthorized.selector);
        manager.openPosition(p);
    }

    function testOpenPositionInvalidInputReverts() public {
        PositionManager.OpenPositionParams memory p = _defaultOpenParams();

        p.owner = address(0);
        vm.prank(relayer);
        vm.expectRevert(Errors.InvalidAddress.selector);
        manager.openPosition(p);

        p = _defaultOpenParams();
        p.marketId = bytes32(0);
        vm.prank(relayer);
        vm.expectRevert(Errors.InvalidMarket.selector);
        manager.openPosition(p);

        p = _defaultOpenParams();
        p.margin = 0;
        vm.prank(relayer);
        vm.expectRevert(Errors.ZeroAmount.selector);
        manager.openPosition(p);

        p = _defaultOpenParams();
        p.entryPriceX18 = 0;
        vm.prank(relayer);
        vm.expectRevert(Errors.ZeroAmount.selector);
        manager.openPosition(p);

        p = _defaultOpenParams();
        p.sizeUsdX18 = 0;
        vm.prank(relayer);
        vm.expectRevert(PositionManager.InvalidSize.selector);
        manager.openPosition(p);

        p = _defaultOpenParams();
        p.leverageX18 = 0;
        vm.prank(relayer);
        vm.expectRevert(Errors.InvalidLeverage.selector);
        manager.openPosition(p);
    }

    function testOpenPositionBoundaryAndSecondActiveRevert() public {
        PositionManager.OpenPositionParams memory p = _defaultOpenParams();
        p.leverageX18 = 20e18;
        vm.prank(relayer);
        manager.openPosition(p);

        vm.prank(relayer);
        vm.expectRevert(PositionManager.PositionAlreadyOpen.selector);
        manager.openPosition(p);
    }

    function testOpenPositionRejectsInactiveMarket() public {
        bytes32 inactive = keccak256("INACTIVE");
        Types.MarketConfig memory m = Types.MarketConfig({
            isActive: false,
            oracle: address(0x1111),
            collateralToken: address(token),
            maxLeverageX18: 20e18,
            maintenanceMarginBps: 800,
            liquidationPenaltyBps: 100,
            maxOpenInterestUsdX18: 100_000_000e18
        });
        config.setMarketConfig(inactive, m);

        PositionManager.OpenPositionParams memory p = _defaultOpenParams();
        p.marketId = inactive;
        vm.prank(relayer);
        vm.expectRevert(Errors.InvalidMarket.selector);
        manager.openPosition(p);
    }

    function testInsuranceHookActivatesAndStoresSnapshot() public {
        manager.setInsuranceController(address(insurance));
        insurance.setOpenReturnValue(true);

        PositionManager.OpenPositionParams memory p = _defaultOpenParams();
        p.insuranceTermId = bytes32("term-1");
        vm.prank(relayer);
        manager.openPosition(p);

        Types.Position memory pos = manager.getPosition(user, marketId);
        _assertEq(uint256(uint8(pos.insuranceStatus)), uint256(uint8(Types.InsuranceStatus.Active)));
        _assertEq(insurance.openCallCount(), 1);
        _assertEq(insurance.lastOpenUser(), user);
        _assertEq(insurance.lastOpenMarketId(), marketId);
        _assertEq(insurance.lastOpenPositionId(), 1);
    }

    function testIncreasePositionHappyPathAndEvent() public {
        token.mint(user, 1_000_000_000_000_000_000_000_000_000_000);
        vm.prank(user);
        vault.deposit(1_000_000_000_000_000_000_000_000_000_000);

        PositionManager.OpenPositionParams memory p = _defaultOpenParams();
        p.margin = 20_000_000_000_000_000_000_000;
        vm.prank(relayer);
        manager.openPosition(p);

        PositionManager.IncreasePositionParams memory inc = PositionManager.IncreasePositionParams({
            owner: user,
            marketId: marketId,
            sizeDeltaUsdX18: 20_000e18,
            executionPriceX18: 2_200e18,
            additionalMargin: 0
        });

        vm.expectEmit(true, false, false, true);
        emit Events.PositionIncreased(1, 120_000e18, 0);
        vm.prank(relayer);
        manager.increasePosition(inc);

        Types.Position memory pos = manager.getPosition(user, marketId);
        _assertEq(pos.sizeUsdX18, 120_000e18);
        _assertEq(pos.collateralAmount, p.margin);
        _assertEq(vault.lockedMargin(user), p.margin);
    }

    function testAddMarginHappyPathAndEvent() public {
        vm.prank(relayer);
        manager.openPosition(_defaultOpenParams());

        vm.expectEmit(true, true, true, true);
        emit Events.PositionMarginAdded(1, user, marketId, 1_000e6, 11_000e6);
        vm.prank(user);
        manager.addMargin(marketId, 1_000e6);

        Types.Position memory pos = manager.getPosition(user, marketId);
        _assertEq(pos.collateralAmount, 11_000e6);
        _assertEq(vault.lockedMargin(user), 11_000e6);
    }

    function testAddMarginRequiresOpenPositionAndNonZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(Errors.InactivePosition.selector);
        manager.addMargin(marketId, 1_000e6);

        vm.prank(relayer);
        manager.openPosition(_defaultOpenParams());

        vm.prank(user);
        vm.expectRevert(Errors.ZeroAmount.selector);
        manager.addMargin(marketId, 0);
    }

    function testAddMarginSucceedsWhileLiquidationEngineIsConfigured() public {
        manager.setInsuranceController(address(insurance));
        insurance.setOpenReturnValue(true);

        PositionManager.OpenPositionParams memory p = _defaultOpenParams();
        p.insuranceTermId = bytes32("insured");
        vm.prank(relayer);
        manager.openPosition(p);

        markFeed.setAnswer(1_700e8, block.timestamp);
        indexFeed.setAnswer(1_700e8, block.timestamp);
        liquidationEngine.liquidate(user, marketId);

        _assertEq(liquidationEngine.getGracePeriodExpiry(user, marketId), block.timestamp + 300);

        vm.prank(user);
        manager.addMargin(marketId, 20_000e6);

        Types.Position memory pos = manager.getPosition(user, marketId);
        _assertEq(pos.collateralAmount, 30_000e6);
        _assertEq(vault.lockedMargin(user), 30_000e6);
    }

    function testIncreasePositionAuthorizationAndInvalidInput() public {
        vm.prank(relayer);
        manager.openPosition(_defaultOpenParams());

        PositionManager.IncreasePositionParams memory inc = PositionManager.IncreasePositionParams({
            owner: user,
            marketId: marketId,
            sizeDeltaUsdX18: 1,
            executionPriceX18: 1,
            additionalMargin: 0
        });

        vm.prank(nonRelayer);
        vm.expectRevert(Errors.Unauthorized.selector);
        manager.increasePosition(inc);

        inc.sizeDeltaUsdX18 = 0;
        vm.prank(relayer);
        vm.expectRevert(Errors.ZeroAmount.selector);
        manager.increasePosition(inc);

        inc.sizeDeltaUsdX18 = 1e18;
        inc.executionPriceX18 = 0;
        vm.prank(relayer);
        vm.expectRevert(Errors.ZeroAmount.selector);
        manager.increasePosition(inc);
    }

    function testIncreasePositionBlockedDuringLiquidationGracePeriod() public {
        manager.setInsuranceController(address(insurance));
        insurance.setOpenReturnValue(true);

        PositionManager.OpenPositionParams memory p = _defaultOpenParams();
        p.insuranceTermId = bytes32("insured");
        vm.prank(relayer);
        manager.openPosition(p);

        markFeed.setAnswer(1_700e8, block.timestamp);
        indexFeed.setAnswer(1_700e8, block.timestamp);
        liquidationEngine.liquidate(user, marketId);

        PositionManager.IncreasePositionParams memory inc = PositionManager.IncreasePositionParams({
            owner: user,
            marketId: marketId,
            sizeDeltaUsdX18: 10_000e18,
            executionPriceX18: 1_700e18,
            additionalMargin: 0
        });
        vm.prank(relayer);
        vm.expectRevert(Errors.GracePeriodActive.selector);
        manager.increasePosition(inc);
    }

    function testIncreasePositionRevertsWhenLeverageExceeded() public {
        PositionManager.OpenPositionParams memory p = _defaultOpenParams();
        p.sizeUsdX18 = 200_000e18;
        p.margin = 10_000e6;
        p.leverageX18 = 20e18;
        vm.prank(relayer);
        manager.openPosition(p);

        PositionManager.IncreasePositionParams memory inc = PositionManager.IncreasePositionParams({
            owner: user,
            marketId: marketId,
            sizeDeltaUsdX18: 1e18,
            executionPriceX18: 2_100e18,
            additionalMargin: 0
        });
        vm.prank(relayer);
        vm.expectRevert(Errors.InvalidLeverage.selector);
        manager.increasePosition(inc);
    }

    function testReducePositionHappyPathAndEvent() public {
        vm.prank(relayer);
        manager.openPosition(_defaultOpenParams());

        PositionManager.ReducePositionParams memory r = PositionManager.ReducePositionParams({
            owner: user,
            marketId: marketId,
            sizeDeltaUsdX18: 40_000e18,
            executionPriceX18: 2_100e18
        });

        vm.expectEmit(true, false, false, true);
        emit Events.PositionReduced(1, 40_000e18, 2_000e18);
        vm.prank(relayer);
        manager.reducePosition(r);

        Types.Position memory pos = manager.getPosition(user, marketId);
        _assertEq(pos.sizeUsdX18, 60_000e18);
        _assertEq(pos.collateralAmount, 6_000e6);
        _assertEq(vault.lockedMargin(user), 6_000e6);
    }

    function testReducePositionAllowedDuringLiquidationGracePeriod() public {
        manager.setInsuranceController(address(insurance));
        insurance.setOpenReturnValue(true);

        PositionManager.OpenPositionParams memory p = _defaultOpenParams();
        p.insuranceTermId = bytes32("insured");
        vm.prank(relayer);
        manager.openPosition(p);

        markFeed.setAnswer(1_700e8, block.timestamp);
        indexFeed.setAnswer(1_700e8, block.timestamp);
        liquidationEngine.liquidate(user, marketId);

        PositionManager.ReducePositionParams memory r = PositionManager.ReducePositionParams({
            owner: user,
            marketId: marketId,
            sizeDeltaUsdX18: 20_000e18,
            executionPriceX18: 1_700e18
        });
        vm.prank(relayer);
        manager.reducePosition(r);

        Types.Position memory pos = manager.getPosition(user, marketId);
        _assertEq(pos.sizeUsdX18, 80_000e18);
    }

    function testReducePositionInvalidInputAndBoundaryReverts() public {
        vm.prank(relayer);
        manager.openPosition(_defaultOpenParams());

        PositionManager.ReducePositionParams memory r =
            PositionManager.ReducePositionParams({owner: user, marketId: marketId, sizeDeltaUsdX18: 0, executionPriceX18: 1});
        vm.prank(relayer);
        vm.expectRevert(Errors.ZeroAmount.selector);
        manager.reducePosition(r);

        r = PositionManager.ReducePositionParams({owner: user, marketId: marketId, sizeDeltaUsdX18: 1, executionPriceX18: 0});
        vm.prank(relayer);
        vm.expectRevert(Errors.ZeroAmount.selector);
        manager.reducePosition(r);

        r = PositionManager.ReducePositionParams({
            owner: user,
            marketId: marketId,
            sizeDeltaUsdX18: 100_000e18,
            executionPriceX18: 2_100e18
        });
        vm.prank(relayer);
        vm.expectRevert(PositionManager.InvalidSize.selector);
        manager.reducePosition(r);
    }

    function testClosePositionHappyPathStateAndEvent() public {
        vm.prank(relayer);
        manager.openPosition(_defaultOpenParams());

        vm.warp(block.timestamp + 10);
        PositionManager.ClosePositionParams memory c =
            PositionManager.ClosePositionParams({owner: user, marketId: marketId, executionPriceX18: 2_050e18});
        vm.expectEmit(true, false, false, true);
        emit Events.PositionClosed(1, 2_500e18, 2_050e18);
        vm.prank(relayer);
        manager.closePosition(c);

        Types.Position memory pos = manager.getPosition(user, marketId);
        _assertEq(uint256(uint8(pos.status)), uint256(uint8(Types.PositionStatus.Closed)));
        _assertEq(pos.sizeUsdX18, 0);
        _assertEq(pos.collateralAmount, 0);
        _assertEq(pos.leverageX18, 0);
        _assertEq(vault.lockedMargin(user), 0);
        assert(pos.closedAt > pos.openedAt);
    }

    function testClosePositionAuthorizationAndInvalidInputReverts() public {
        vm.prank(relayer);
        manager.openPosition(_defaultOpenParams());
        PositionManager.ClosePositionParams memory c =
            PositionManager.ClosePositionParams({owner: user, marketId: marketId, executionPriceX18: 2_050e18});

        vm.prank(nonRelayer);
        vm.expectRevert(Errors.Unauthorized.selector);
        manager.closePosition(c);

        c.executionPriceX18 = 0;
        vm.prank(relayer);
        vm.expectRevert(Errors.ZeroAmount.selector);
        manager.closePosition(c);
    }

    function testClosePositionWithInsuranceTransitionsToSettledAndCallsHook() public {
        manager.setInsuranceController(address(insurance));
        insurance.setOpenReturnValue(true);

        PositionManager.OpenPositionParams memory p = _defaultOpenParams();
        p.insuranceTermId = bytes32("insured");
        vm.prank(relayer);
        manager.openPosition(p);

        PositionManager.ClosePositionParams memory c =
            PositionManager.ClosePositionParams({owner: user, marketId: marketId, executionPriceX18: 2_000e18});
        vm.prank(relayer);
        manager.closePosition(c);

        Types.Position memory pos = manager.getPosition(user, marketId);
        _assertEq(uint256(uint8(pos.insuranceStatus)), uint256(uint8(Types.InsuranceStatus.Settled)));
        _assertEq(insurance.closeCallCount(), 1);
    }

    function testMarkLiquidatedHappyPathEventsAndState() public {
        PositionManager.OpenPositionParams memory p = _defaultOpenParams();
        p.isLong = false;
        vm.prank(relayer);
        manager.openPosition(p);

        vm.expectEmit(true, true, false, true);
        emit Events.LiquidationTriggered(1, address(0xD1E), 2_300e18);
        vm.expectEmit(true, true, false, true);
        emit Events.LiquidationCompleted(1, address(0xD1E), -15_000e18, 0);
        vm.prank(relayer);
        manager.markLiquidated(user, marketId, address(0xD1E), 2_300e18);

        Types.Position memory pos = manager.getPosition(user, marketId);
        _assertEq(uint256(uint8(pos.status)), uint256(uint8(Types.PositionStatus.Liquidated)));
        _assertEq(pos.sizeUsdX18, 0);
        _assertEq(vault.lockedMargin(user), 0);
    }

    function testMarkLiquidatedInvalidInputAndAuthorizationReverts() public {
        vm.prank(relayer);
        manager.openPosition(_defaultOpenParams());

        vm.prank(nonRelayer);
        vm.expectRevert(Errors.Unauthorized.selector);
        manager.markLiquidated(user, marketId, address(0xD1E), 2_200e18);

        vm.prank(relayer);
        vm.expectRevert(Errors.InvalidLiquidationState.selector);
        manager.markLiquidated(user, marketId, address(0), 2_200e18);

        vm.prank(relayer);
        vm.expectRevert(Errors.InvalidLiquidationState.selector);
        manager.markLiquidated(user, marketId, address(0xD1E), 0);
    }

    function testMarkLiquidatedWithInsuranceTransitionsSettledAndCallsHook() public {
        manager.setInsuranceController(address(insurance));
        insurance.setOpenReturnValue(true);
        PositionManager.OpenPositionParams memory p = _defaultOpenParams();
        p.insuranceTermId = bytes32("insured");
        vm.prank(relayer);
        manager.openPosition(p);

        vm.prank(relayer);
        manager.markLiquidated(user, marketId, address(0xD1E), 1_500e18);

        Types.Position memory pos = manager.getPosition(user, marketId);
        _assertEq(uint256(uint8(pos.insuranceStatus)), uint256(uint8(Types.InsuranceStatus.Settled)));
        _assertEq(insurance.liquidateCallCount(), 1);
    }

    function testSettersAuthorizationAndInputValidation() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        manager.setRelayer(address(0x1234), true);

        vm.expectRevert(Errors.InvalidAddress.selector);
        manager.setRelayer(address(0), true);

        vm.prank(nonOwner);
        vm.expectRevert();
        manager.setInsuranceController(address(insurance));
    }

    function testGetPositionDefaultStateForUninitializedSlot() public view {
        Types.Position memory pos = manager.getPosition(address(0x1234), keccak256("UNKNOWN"));
        _assertEq(pos.id, 0);
        _assertEq(uint256(uint8(pos.status)), uint256(uint8(Types.PositionStatus.None)));
    }

    function _defaultOpenParams() internal view returns (PositionManager.OpenPositionParams memory p) {
        p = PositionManager.OpenPositionParams({
            owner: user,
            marketId: marketId,
            isLong: true,
            sizeUsdX18: 100_000e18,
            entryPriceX18: 2_000e18,
            leverageX18: 10e18,
            margin: 10_000e6,
            insuranceTermId: bytes32(0)
        });
    }

    function _assertEq(uint256 a, uint256 b) internal pure {
        assert(a == b);
    }

    function _assertEq(address a, address b) internal pure {
        assert(a == b);
    }

    function _assertEq(bytes32 a, bytes32 b) internal pure {
        assert(a == b);
    }
}
