// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Types {
    enum PositionSide {
        Long,
        Short
    }

    struct Position {
        address account;
        address asset;
        uint256 size;
        uint256 entryPriceX18;
        PositionSide side;
    }

    struct RiskParams {
        uint256 maxLeverageX18;
        uint256 maintenanceMarginBps;
    }
}