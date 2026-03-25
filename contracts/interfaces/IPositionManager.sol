// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "../libraries/Types.sol";

interface IPositionManager {
    function addMargin(bytes32 marketId, uint256 amount) external;
    function getPosition(address user, bytes32 marketId) external view returns (Types.Position memory position);
    function markLiquidated(address user, bytes32 marketId, address liquidator, uint256 executionPriceX18) external;
}
