// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Errors} from "../libraries/Errors.sol";
import {Types} from "../libraries/Types.sol";

contract RiskConfig {
    address public owner;
    mapping(address => Types.RiskParams) public riskParams;

    constructor() {
        owner = msg.sender;
    }

    function setRiskParams(address asset, Types.RiskParams calldata params) external {
        if (msg.sender != owner) revert Errors.Unauthorized();
        riskParams[asset] = params;
    }
}