// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "../vendor/openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "../vendor/openzeppelin/contracts/access/Ownable2Step.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {Errors} from "../libraries/Errors.sol";
import {Events} from "../libraries/Events.sol";
import {MathLib} from "../libraries/MathLib.sol";

interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title OracleAdapter
/// @notice Normalizes and validates market mark/index prices for settlement and liquidation.
/// @dev Supports pluggable feed addresses per market to keep oracle provider choice extensible.
contract OracleAdapter is Ownable2Step, IOracleAdapter {
    uint256 private constant X18 = 1e18;
    uint256 private constant BPS_DIVISOR = 10_000;

    struct MarketOracleConfig {
        address markFeed;
        address indexFeed;
        uint32 maxStaleness;
        uint16 maxDeviationBps;
        uint8 markFeedDecimals;
        uint8 indexFeedDecimals;
        uint256 minPriceX18;
        uint256 maxPriceX18;
        bool isActive;
    }

    mapping(bytes32 marketId => MarketOracleConfig config) private _marketConfigs;

    /// @notice Deploys OracleAdapter with governance owner.
    /// @param initialOwner Owner allowed to set market feed configuration.
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Sets mark/index feed config for a market.
    /// @param marketId Market identifier.
    /// @param markFeed Mark price feed.
    /// @param indexFeed Index price feed.
    /// @param maxStaleness Maximum age in seconds accepted for feed updates.
    /// @param maxDeviationBps Maximum allowed mark-index deviation in bps.
    /// @param minPriceX18 Lower accepted bound of normalized price.
    /// @param maxPriceX18 Upper accepted bound of normalized price.
    function setMarketFeeds(
        bytes32 marketId,
        address markFeed,
        address indexFeed,
        uint32 maxStaleness,
        uint16 maxDeviationBps,
        uint256 minPriceX18,
        uint256 maxPriceX18
    ) external onlyOwner {
        if (marketId == bytes32(0) || markFeed == address(0) || indexFeed == address(0)) revert Errors.InvalidMarket();
        if (maxStaleness == 0 || maxDeviationBps > BPS_DIVISOR) revert Errors.InvalidOracleConfig();
        if (minPriceX18 == 0 || minPriceX18 >= maxPriceX18) revert Errors.InvalidOracleConfig();

        uint8 markDecimals = IPriceFeed(markFeed).decimals();
        uint8 indexDecimals = IPriceFeed(indexFeed).decimals();
        if (markDecimals > 18 || indexDecimals > 18) revert Errors.InvalidOracleConfig();

        _marketConfigs[marketId] = MarketOracleConfig({
            markFeed: markFeed,
            indexFeed: indexFeed,
            maxStaleness: maxStaleness,
            maxDeviationBps: maxDeviationBps,
            markFeedDecimals: markDecimals,
            indexFeedDecimals: indexDecimals,
            minPriceX18: minPriceX18,
            maxPriceX18: maxPriceX18,
            isActive: true
        });

        emit Events.OracleMarketConfigured(
            marketId, markFeed, indexFeed, maxStaleness, maxDeviationBps, minPriceX18, maxPriceX18
        );
    }

    /// @notice Returns normalized mark price for a market (x18).
    /// @param marketId Market identifier.
    function getMarkPrice(bytes32 marketId) external view override returns (uint256 priceX18) {
        (uint256 markPriceX18,,,) = _validatedPrices(marketId);
        return markPriceX18;
    }

    /// @notice Returns normalized index price for a market (x18).
    /// @param marketId Market identifier.
    function getIndexPrice(bytes32 marketId) external view override returns (uint256 priceX18) {
        (,uint256 indexPriceX18,,) = _validatedPrices(marketId);
        return indexPriceX18;
    }

    /// @notice Returns market oracle configuration snapshot.
    /// @param marketId Market identifier.
    function getMarketOracleConfig(bytes32 marketId) external view returns (MarketOracleConfig memory) {
        return _marketConfigs[marketId];
    }

    function _validatedPrices(bytes32 marketId)
        internal
        view
        returns (uint256 markPriceX18, uint256 indexPriceX18, uint256 markUpdatedAt, uint256 indexUpdatedAt)
    {
        MarketOracleConfig memory cfg = _marketConfigs[marketId];
        if (!cfg.isActive) revert Errors.InvalidMarket();

        (markPriceX18, markUpdatedAt) = _readNormalized(cfg.markFeed, cfg.markFeedDecimals);
        (indexPriceX18, indexUpdatedAt) = _readNormalized(cfg.indexFeed, cfg.indexFeedDecimals);

        if (block.timestamp > markUpdatedAt + cfg.maxStaleness || block.timestamp > indexUpdatedAt + cfg.maxStaleness) {
            revert Errors.StalePrice();
        }

        _checkPriceBounds(markPriceX18, cfg.minPriceX18, cfg.maxPriceX18);
        _checkPriceBounds(indexPriceX18, cfg.minPriceX18, cfg.maxPriceX18);
        _checkDeviation(markPriceX18, indexPriceX18, cfg.maxDeviationBps);
    }

    function _readNormalized(address feed, uint8 feedDecimals) internal view returns (uint256 priceX18, uint256 updatedAt) {
        (, int256 answer,, uint256 ts,) = IPriceFeed(feed).latestRoundData();
        if (answer <= 0 || ts == 0 || ts > block.timestamp) revert Errors.InvalidPrice();

        uint256 rawPrice = uint256(answer);
        if (feedDecimals == 18) return (rawPrice, ts);
        uint256 scale = 10 ** (18 - feedDecimals);
        return (rawPrice * scale, ts);
    }

    function _checkPriceBounds(uint256 priceX18, uint256 minPriceX18, uint256 maxPriceX18) internal pure {
        if (priceX18 < minPriceX18 || priceX18 > maxPriceX18) revert Errors.InvalidPrice();
    }

    function _checkDeviation(uint256 markPriceX18, uint256 indexPriceX18, uint16 maxDeviationBps) internal pure {
        if (maxDeviationBps == 0) return;
        uint256 diff = MathLib.absDiff(markPriceX18, indexPriceX18);
        uint256 deviationBps = (diff * BPS_DIVISOR) / indexPriceX18;
        if (deviationBps > maxDeviationBps) revert Errors.PriceDeviationTooHigh();
    }
}
