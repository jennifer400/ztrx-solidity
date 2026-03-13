// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IZTRXNFTBenefits {
    function activeBenefitToken(address user) external view returns (uint256 tokenId);
    function tradingFeeDiscountOf(address user) external view returns (uint16);
    function insuranceBenefitAdjustmentsOf(address user)
        external
        view
        returns (uint16 premiumDiscountBps, uint16 liquidationProtectionBoostBps);
    function liquidityBenefitAdjustmentsOf(address user)
        external
        view
        returns (uint16 lpYieldBoostBps, uint16 lpExitCooldownReductionBps);

    function benefitDetailsOf(address user)
        external
        view
        returns (
            uint16 tradingFeeDiscountBps,
            uint16 tokenAirdropBonusBps,
            uint16 insurancePremiumDiscountBps,
            uint16 liquidationProtectionBoostBps,
            uint16 tradingCompetitionBoostBps,
            uint16 lpYieldBoostBps,
            uint16 lpExitCooldownReductionBps,
            bool partnerWhitelistEligible,
            bool priorityAccessEligible
        );
}
