// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ZTRXNFT} from "../contracts/core/ZTRXNFT.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes calldata) external;
    function expectRevert(bytes4) external;
}

contract ERC721ReceiverMock {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract ZTRXNFTTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    ZTRXNFT private nft;

    address private owner = address(this);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xCA11);

    function setUp() public {
        nft = new ZTRXNFT(owner, "ipfs://ztrx-metadata/", ".json");
    }

    function testOwnerCanConfigureThemeBenefits() public {
        ZTRXNFT.BenefitConfig memory config = ZTRXNFT.BenefitConfig({
            tradingFeeDiscountBps: 1_500,
            tokenAirdropBonusBps: 200,
            insurancePremiumDiscountBps: 800,
            liquidationProtectionBoostBps: 1_200,
            tradingCompetitionBoostBps: 1_000,
            lpYieldBoostBps: 700,
            lpExitCooldownReductionBps: 2_000,
            partnerWhitelistEligible: true,
            priorityAccessEligible: true
        });

        nft.setThemeBenefits(ZTRXNFT.Theme.Oracle, config);

        ZTRXNFT.BenefitConfig memory saved = nft.themeBenefits(ZTRXNFT.Theme.Oracle);
        assert(saved.tradingFeeDiscountBps == 1_500);
        assert(saved.tokenAirdropBonusBps == 200);
        assert(saved.insurancePremiumDiscountBps == 800);
        assert(saved.liquidationProtectionBoostBps == 1_200);
        assert(saved.tradingCompetitionBoostBps == 1_000);
        assert(saved.lpYieldBoostBps == 700);
        assert(saved.lpExitCooldownReductionBps == 2_000);
        assert(saved.partnerWhitelistEligible);
        assert(saved.priorityAccessEligible);
    }

    function testRejectsInvalidBenefitBps() public {
        ZTRXNFT.BenefitConfig memory config = ZTRXNFT.BenefitConfig({
            tradingFeeDiscountBps: 10_001,
            tokenAirdropBonusBps: 0,
            insurancePremiumDiscountBps: 0,
            liquidationProtectionBoostBps: 0,
            tradingCompetitionBoostBps: 0,
            lpYieldBoostBps: 0,
            lpExitCooldownReductionBps: 0,
            partnerWhitelistEligible: false,
            priorityAccessEligible: false
        });

        vm.expectRevert(abi.encodeWithSelector(ZTRXNFT.InvalidBpsValue.selector, 10_001));
        nft.setThemeBenefits(ZTRXNFT.Theme.Sentinel, config);
    }

    function testThemeRangesMatchSupplyPlan() public view {
        assert(uint256(nft.tokenTheme(1)) == uint256(ZTRXNFT.Theme.Sentinel));
        assert(uint256(nft.tokenTheme(1_200)) == uint256(ZTRXNFT.Theme.Sentinel));
        assert(uint256(nft.tokenTheme(1_201)) == uint256(ZTRXNFT.Theme.Guardian));
        assert(uint256(nft.tokenTheme(1_700)) == uint256(ZTRXNFT.Theme.Guardian));
        assert(uint256(nft.tokenTheme(1_701)) == uint256(ZTRXNFT.Theme.Bastion));
        assert(uint256(nft.tokenTheme(1_920)) == uint256(ZTRXNFT.Theme.Bastion));
        assert(uint256(nft.tokenTheme(1_921)) == uint256(ZTRXNFT.Theme.Oracle));
        assert(uint256(nft.tokenTheme(2_000)) == uint256(ZTRXNFT.Theme.Oracle));
    }

    function testAssignedUserCanClaimOwnToken() public {
        address[] memory recipients = new address[](2);
        uint256[] memory tokenIds = new uint256[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        tokenIds[0] = 7;
        tokenIds[1] = 1_550;

        nft.assignRecipients(recipients, tokenIds);

        vm.prank(alice);
        nft.claim(7);

        assert(nft.ownerOf(7) == alice);
        assert(nft.balanceOf(alice) == 1);
        assert(nft.assignedRecipient(7) == address(0));
        assert(nft.activeBenefitToken(alice) == 7);
        assert(nft.totalMinted() == 1);
    }

    function testClaimBatchWorksForSingleWallet() public {
        address[] memory recipients = new address[](2);
        uint256[] memory tokenIds = new uint256[](2);
        recipients[0] = alice;
        recipients[1] = alice;
        tokenIds[0] = 100;
        tokenIds[1] = 1_950;

        nft.assignRecipients(recipients, tokenIds);

        vm.prank(alice);
        nft.claimBatch(tokenIds);

        assert(nft.ownerOf(100) == alice);
        assert(nft.ownerOf(1_950) == alice);
        assert(nft.balanceOf(alice) == 2);
        assert(nft.totalMinted() == 2);
    }

    function testUnassignedWalletCannotClaim() public {
        address[] memory recipients = new address[](1);
        uint256[] memory tokenIds = new uint256[](1);
        recipients[0] = alice;
        tokenIds[0] = 15;
        nft.assignRecipients(recipients, tokenIds);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ZTRXNFT.NotAssignedRecipient.selector, 15, bob));
        nft.claim(15);
    }

    function testOwnerCanReassignBeforeMint() public {
        address[] memory recipients = new address[](1);
        uint256[] memory tokenIds = new uint256[](1);
        recipients[0] = alice;
        tokenIds[0] = 88;
        nft.assignRecipients(recipients, tokenIds);

        nft.reassignRecipient(88, bob);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ZTRXNFT.NotAssignedRecipient.selector, 88, alice));
        nft.claim(88);

        vm.prank(bob);
        nft.claim(88);
        assert(nft.ownerOf(88) == bob);
    }

    function testTokenUriUsesTokenId() public {
        address[] memory recipients = new address[](1);
        uint256[] memory tokenIds = new uint256[](1);
        recipients[0] = alice;
        tokenIds[0] = 2_000;
        nft.assignRecipients(recipients, tokenIds);

        vm.prank(alice);
        nft.claim(2_000);

        assert(_eq(nft.tokenURI(2_000), "ipfs://ztrx-metadata/2000.json"));
    }

    function testMintedTokenCanReadItsBenefitProfile() public {
        ZTRXNFT.BenefitConfig memory config = ZTRXNFT.BenefitConfig({
            tradingFeeDiscountBps: 500,
            tokenAirdropBonusBps: 200,
            insurancePremiumDiscountBps: 300,
            liquidationProtectionBoostBps: 700,
            tradingCompetitionBoostBps: 1_500,
            lpYieldBoostBps: 400,
            lpExitCooldownReductionBps: 1_000,
            partnerWhitelistEligible: true,
            priorityAccessEligible: false
        });
        nft.setThemeBenefits(ZTRXNFT.Theme.Sentinel, config);

        address[] memory recipients = new address[](1);
        uint256[] memory tokenIds = new uint256[](1);
        recipients[0] = alice;
        tokenIds[0] = 99;
        nft.assignRecipients(recipients, tokenIds);

        vm.prank(alice);
        nft.claim(99);

        ZTRXNFT.BenefitConfig memory saved = nft.tokenBenefits(99);
        assert(saved.tradingFeeDiscountBps == 500);
        assert(saved.tokenAirdropBonusBps == 200);
        assert(saved.insurancePremiumDiscountBps == 300);
        assert(saved.liquidationProtectionBoostBps == 700);
        assert(saved.tradingCompetitionBoostBps == 1_500);
        assert(saved.lpYieldBoostBps == 400);
        assert(saved.lpExitCooldownReductionBps == 1_000);
        assert(saved.partnerWhitelistEligible);
        assert(!saved.priorityAccessEligible);
    }

    function testOwnerCanSwitchActiveBenefitToken() public {
        ZTRXNFT.BenefitConfig memory sentinelConfig = ZTRXNFT.BenefitConfig({
            tradingFeeDiscountBps: 500,
            tokenAirdropBonusBps: 200,
            insurancePremiumDiscountBps: 300,
            liquidationProtectionBoostBps: 100,
            tradingCompetitionBoostBps: 500,
            lpYieldBoostBps: 200,
            lpExitCooldownReductionBps: 500,
            partnerWhitelistEligible: false,
            priorityAccessEligible: false
        });
        ZTRXNFT.BenefitConfig memory oracleConfig = ZTRXNFT.BenefitConfig({
            tradingFeeDiscountBps: 2_000,
            tokenAirdropBonusBps: 200,
            insurancePremiumDiscountBps: 1_200,
            liquidationProtectionBoostBps: 1_500,
            tradingCompetitionBoostBps: 2_500,
            lpYieldBoostBps: 1_500,
            lpExitCooldownReductionBps: 6_000,
            partnerWhitelistEligible: true,
            priorityAccessEligible: true
        });
        nft.setThemeBenefits(ZTRXNFT.Theme.Sentinel, sentinelConfig);
        nft.setThemeBenefits(ZTRXNFT.Theme.Oracle, oracleConfig);

        address[] memory recipients = new address[](2);
        uint256[] memory tokenIds = new uint256[](2);
        recipients[0] = alice;
        recipients[1] = alice;
        tokenIds[0] = 5;
        tokenIds[1] = 1_999;
        nft.assignRecipients(recipients, tokenIds);

        vm.prank(alice);
        nft.claimBatch(tokenIds);

        ZTRXNFT.BenefitConfig memory initialBenefit = nft.benefitOf(alice);
        assert(nft.activeBenefitToken(alice) == 5);
        assert(initialBenefit.tradingFeeDiscountBps == 500);

        vm.prank(alice);
        nft.setActiveBenefitToken(1_999);

        ZTRXNFT.BenefitConfig memory switchedBenefit = nft.benefitOf(alice);
        assert(nft.activeBenefitToken(alice) == 1_999);
        assert(switchedBenefit.tradingFeeDiscountBps == 2_000);
        assert(switchedBenefit.lpYieldBoostBps == 1_500);
        assert(switchedBenefit.partnerWhitelistEligible);
        assert(switchedBenefit.priorityAccessEligible);
    }

    function testActiveBenefitTokenClearsOnTransfer() public {
        address[] memory recipients = new address[](1);
        uint256[] memory tokenIds = new uint256[](1);
        recipients[0] = alice;
        tokenIds[0] = 123;
        nft.assignRecipients(recipients, tokenIds);

        vm.prank(alice);
        nft.claim(123);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 123);

        assert(nft.activeBenefitToken(alice) == 0);
        assert(nft.activeBenefitToken(bob) == 123);
    }

    function testSupportsTransferAndApprovalFlow() public {
        address[] memory recipients = new address[](1);
        uint256[] memory tokenIds = new uint256[](1);
        recipients[0] = alice;
        tokenIds[0] = 301;
        nft.assignRecipients(recipients, tokenIds);

        vm.prank(alice);
        nft.claim(301);

        vm.startPrank(alice);
        nft.approve(bob, 301);
        vm.stopPrank();

        vm.prank(bob);
        nft.transferFrom(alice, carol, 301);

        assert(nft.ownerOf(301) == carol);
        assert(nft.balanceOf(carol) == 1);
    }

    function testSafeTransferToReceiverContract() public {
        ERC721ReceiverMock receiver = new ERC721ReceiverMock();
        address[] memory recipients = new address[](1);
        uint256[] memory tokenIds = new uint256[](1);
        recipients[0] = alice;
        tokenIds[0] = 450;
        nft.assignRecipients(recipients, tokenIds);

        vm.prank(alice);
        nft.claim(450);

        vm.prank(alice);
        nft.safeTransferFrom(alice, address(receiver), 450);

        assert(nft.ownerOf(450) == address(receiver));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
