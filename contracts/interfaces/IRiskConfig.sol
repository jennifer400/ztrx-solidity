// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "../libraries/Types.sol";

interface IRiskConfig {
    function getMarketConfig(bytes32 marketId) external view returns (Types.MarketConfig memory config);
    function maxCoverageRatioBps() external view returns (uint256);
    function premiumTreasuryBps() external view returns (uint256);
    function vaultUtilizationLimitBps() external view returns (uint256);
    function liquidationPenaltyBps() external view returns (uint256);
    function quoteSigner() external view returns (address);
}
