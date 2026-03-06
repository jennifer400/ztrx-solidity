// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFeeRouter {
    function routePremium(address payer, uint256 amount) external;
    function routeProtocolFee(address payer, uint256 amount) external;
    function getUnroutedBalance() external view returns (uint256);
}
