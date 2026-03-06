// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Errors} from "../libraries/Errors.sol";

contract FeeRouter {
    address public treasury;
    uint256 public accruedFees;

    constructor(address treasury_) {
        if (treasury_ == address(0)) revert Errors.InvalidAddress();
        treasury = treasury_;
    }

    receive() external payable {
        accruedFees += msg.value;
    }

    function routeFees() external {
        uint256 amount = accruedFees;
        accruedFees = 0;
        (bool ok,) = treasury.call{value: amount}("");
        require(ok, "TRANSFER_FAILED");
    }
}