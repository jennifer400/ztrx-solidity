// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFeeRouter {
    function routePremium(address payer, uint256 amount) external;
    function routeProtocolFee(address payer, uint256 amount) external;
    function routeProtocolFeeWithBenefits(address payer, address benefitAccount, uint256 grossAmount)
        external
        returns (uint256 chargedAmount);
    function getUnroutedBalance() external view returns (uint256);
}
