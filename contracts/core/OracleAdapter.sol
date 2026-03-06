// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {Events} from "../libraries/Events.sol";
import {Errors} from "../libraries/Errors.sol";

contract OracleAdapter is IOracleAdapter {
    address public owner;

    struct PriceData {
        uint256 priceX18;
        uint256 updatedAt;
    }

    mapping(address => PriceData) public prices;

    constructor() {
        owner = msg.sender;
    }

    function setPrice(address asset, uint256 priceX18) external {
        if (msg.sender != owner) revert Errors.Unauthorized();
        prices[asset] = PriceData({priceX18: priceX18, updatedAt: block.timestamp});
        emit Events.PriceUpdated(asset, priceX18, block.timestamp);
    }

    function getPrice(address asset) external view override returns (uint256 priceX18, uint256 updatedAt) {
        PriceData memory p = prices[asset];
        return (p.priceX18, p.updatedAt);
    }
}