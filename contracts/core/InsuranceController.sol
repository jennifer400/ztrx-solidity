// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInsuranceController} from "../interfaces/IInsuranceController.sol";
import {Events} from "../libraries/Events.sol";
import {MathLib} from "../libraries/MathLib.sol";

contract InsuranceController is IInsuranceController {
    using MathLib for uint256;

    uint256 public insuranceFund;

    receive() external payable {
        insuranceFund += msg.value;
    }

    function coverLoss(uint256 amount) external override returns (uint256 covered) {
        covered = amount.min(insuranceFund);
        insuranceFund -= covered;
        emit Events.LossCovered(amount, covered);
    }
}