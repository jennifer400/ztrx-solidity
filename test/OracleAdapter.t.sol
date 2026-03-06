// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OracleAdapter} from "../contracts/core/OracleAdapter.sol";
import {Errors} from "../contracts/libraries/Errors.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";

interface Vm {
    function prank(address) external;
    function expectRevert() external;
    function expectRevert(bytes calldata) external;
    function expectRevert(bytes4) external;
    function warp(uint256) external;
}

contract OracleAdapterTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    OracleAdapter private oracle;
    MockPriceFeed private markFeed;
    MockPriceFeed private indexFeed;

    address private owner = address(this);
    address private nonOwner = address(0xBEEF);
    bytes32 private marketId = keccak256("ETH-PERP");

    function setUp() public {
        oracle = new OracleAdapter(owner);
        markFeed = new MockPriceFeed(8);
        indexFeed = new MockPriceFeed(8);

        markFeed.setAnswer(2_000e8, block.timestamp);
        indexFeed.setAnswer(1_995e8, block.timestamp);

        oracle.setMarketFeeds(marketId, address(markFeed), address(indexFeed), 300, 200, 100e18, 1_000_000e18);
    }

    function testStalePriceRejected() public {
        vm.warp(block.timestamp + 301);
        vm.expectRevert(Errors.StalePrice.selector);
        oracle.getMarkPrice(marketId);
    }

    function testInvalidMarketRejected() public {
        vm.expectRevert(Errors.InvalidMarket.selector);
        oracle.getIndexPrice(keccak256("UNKNOWN"));
    }

    function testAdminCanSetFeed() public {
        MockPriceFeed mark2 = new MockPriceFeed(8);
        MockPriceFeed index2 = new MockPriceFeed(8);
        mark2.setAnswer(2_100e8, block.timestamp);
        index2.setAnswer(2_090e8, block.timestamp);

        oracle.setMarketFeeds(keccak256("BTC-PERP"), address(mark2), address(index2), 120, 300, 100e18, 10_000_000e18);
        OracleAdapter.MarketOracleConfig memory cfg = oracle.getMarketOracleConfig(keccak256("BTC-PERP"));
        _assertEq(cfg.markFeed, address(mark2));
        _assertEq(cfg.indexFeed, address(index2));
        _assertEq(uint256(cfg.maxStaleness), 120);
    }

    function testConsumersReceiveNormalizedPriceFormat() public {
        uint256 mark = oracle.getMarkPrice(marketId);
        uint256 index = oracle.getIndexPrice(marketId);

        _assertEq(mark, 2_000e18);
        _assertEq(index, 1_995e18);
    }

    function testNonOwnerCannotSetFeed() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        oracle.setMarketFeeds(marketId, address(markFeed), address(indexFeed), 300, 200, 100e18, 1_000_000e18);
    }

    function _assertEq(uint256 a, uint256 b) internal pure {
        assert(a == b);
    }

    function _assertEq(address a, address b) internal pure {
        assert(a == b);
    }
}
