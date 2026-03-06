// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockInsuranceModule {
    uint256 public openCallCount;
    uint256 public closeCallCount;
    uint256 public liquidateCallCount;
    bool public openReturnValue = true;
    address public lastOpenUser;
    bytes32 public lastOpenMarketId;
    uint256 public lastOpenPositionId;
    bytes32 public lastOpenInsuranceTermId;

    uint256 public processCallCount;
    uint256 public lastPositionId;
    address public lastRecipient;
    uint256 public lastRealizedLoss;
    bool public lastEligible;
    uint256 public claimToReturn;

    function setClaimToReturn(uint256 amount) external {
        claimToReturn = amount;
    }

    function setOpenReturnValue(bool value) external {
        openReturnValue = value;
    }

    function onPositionOpened(address user, bytes32 marketId, uint256 positionId, bytes32 insuranceTermId)
        external
        returns (bool)
    {
        openCallCount += 1;
        lastOpenUser = user;
        lastOpenMarketId = marketId;
        lastOpenPositionId = positionId;
        lastOpenInsuranceTermId = insuranceTermId;
        return insuranceTermId != bytes32(0) && openReturnValue;
    }

    function onPositionClosed(address, bytes32, uint256, bytes32) external {
        closeCallCount += 1;
    }

    function onPositionLiquidated(address, bytes32, uint256, bytes32) external {
        liquidateCallCount += 1;
    }

    function processLiquidationClaim(uint256 positionId, address recipient, uint256 realizedLoss, bool eligible)
        external
        returns (uint256 claimPaid)
    {
        processCallCount += 1;
        lastPositionId = positionId;
        lastRecipient = recipient;
        lastRealizedLoss = realizedLoss;
        lastEligible = eligible;
        return claimToReturn;
    }
}
