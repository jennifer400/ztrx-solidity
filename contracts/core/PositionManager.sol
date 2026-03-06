// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "../libraries/Types.sol";

contract PositionManager {
    uint256 public nextPositionId;
    mapping(uint256 => Types.Position) public positions;

    function openPosition(
        address asset,
        uint256 size,
        uint256 entryPriceX18,
        Types.PositionSide side
    ) external returns (uint256 id) {
        id = ++nextPositionId;
        positions[id] = Types.Position({
            account: msg.sender,
            asset: asset,
            size: size,
            entryPriceX18: entryPriceX18,
            side: side
        });
    }
}