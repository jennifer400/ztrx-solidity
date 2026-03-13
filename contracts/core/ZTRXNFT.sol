// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "../vendor/openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "../vendor/openzeppelin/contracts/access/Ownable2Step.sol";
import {IZTRXNFTBenefits} from "../interfaces/IZTRXNFTBenefits.sol";

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IERC721 is IERC165 {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
    function getApproved(uint256 tokenId) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
}

interface IERC721Metadata is IERC721 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

contract ZTRXNFT is Ownable2Step, IERC721Metadata, IZTRXNFTBenefits {
    uint256 public constant MAX_SUPPLY = 2_000;
    uint256 public constant SENTINEL_SUPPLY = 1_200;
    uint256 public constant GUARDIAN_SUPPLY = 500;
    uint256 public constant BASTION_SUPPLY = 220;
    uint256 public constant ORACLE_SUPPLY = 80;

    string private _name;
    string private _symbol;
    string private _baseTokenURI;
    string private _uriSuffix;

    uint256 private _totalMinted;

    struct BenefitConfig {
        uint16 tradingFeeDiscountBps;
        uint16 tokenAirdropBonusBps;
        uint16 insurancePremiumDiscountBps;
        uint16 liquidationProtectionBoostBps;
        uint16 tradingCompetitionBoostBps;
        uint16 lpYieldBoostBps;
        uint16 lpExitCooldownReductionBps;
        bool partnerWhitelistEligible;
        bool priorityAccessEligible;
    }

    mapping(uint256 tokenId => address owner) private _owners;
    mapping(address owner => uint256 balance) private _balances;
    mapping(uint256 tokenId => address approved) private _tokenApprovals;
    mapping(address owner => mapping(address operator => bool approved)) private _operatorApprovals;
    mapping(uint256 tokenId => address assignee) private _assignedRecipient;
    mapping(Theme theme => BenefitConfig config) private _themeBenefits;
    mapping(address user => uint256 tokenId) private _activeBenefitToken;

    error InvalidAddress();
    error InvalidTokenId(uint256 tokenId);
    error InvalidBpsValue(uint256 value);
    error TokenAlreadyMinted(uint256 tokenId);
    error TokenNotMinted(uint256 tokenId);
    error TokenAlreadyAssigned(uint256 tokenId, address currentAssignee);
    error NotAssignedRecipient(uint256 tokenId, address caller);
    error AssignmentLengthMismatch();
    error TransferToNonReceiver();
    error NotAuthorized(address caller, uint256 tokenId);

    event ClaimAssignmentUpdated(uint256 indexed tokenId, address indexed assignee);
    event TokenClaimed(address indexed claimer, uint256 indexed tokenId, Theme indexed theme);
    event BaseTokenURIUpdated(string newBaseTokenURI, string newSuffix);
    event ActiveBenefitTokenUpdated(address indexed user, uint256 indexed tokenId);
    event ThemeBenefitsUpdated(
        Theme indexed theme,
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

    enum Theme {
        Sentinel,
        Guardian,
        Bastion,
        Oracle
    }

    constructor(address initialOwner, string memory baseTokenURI_, string memory uriSuffix_)
        Ownable(initialOwner)
    {
        _name = "ZTRX NFT";
        _symbol = "ZTRX";
        _baseTokenURI = baseTokenURI_;
        _uriSuffix = uriSuffix_;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC721).interfaceId
            || interfaceId == type(IERC721Metadata).interfaceId;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function totalMinted() external view returns (uint256) {
        return _totalMinted;
    }

    function balanceOf(address owner_) public view returns (uint256) {
        if (owner_ == address(0)) revert InvalidAddress();
        return _balances[owner_];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner_ = _owners[tokenId];
        if (owner_ == address(0)) revert TokenNotMinted(tokenId);
        return owner_;
    }

    function assignedRecipient(uint256 tokenId) external view returns (address) {
        _requireValidTokenId(tokenId);
        return _assignedRecipient[tokenId];
    }

    function activeBenefitToken(address user) public view returns (uint256 tokenId) {
        return _activeBenefitToken[user];
    }

    function tokenTheme(uint256 tokenId) public pure returns (Theme) {
        _requireValidTokenId(tokenId);

        if (tokenId <= SENTINEL_SUPPLY) {
            return Theme.Sentinel;
        }
        if (tokenId <= SENTINEL_SUPPLY + GUARDIAN_SUPPLY) {
            return Theme.Guardian;
        }
        if (tokenId <= SENTINEL_SUPPLY + GUARDIAN_SUPPLY + BASTION_SUPPLY) {
            return Theme.Bastion;
        }
        return Theme.Oracle;
    }

    function themeBenefits(Theme theme) external view returns (BenefitConfig memory) {
        return _themeBenefits[theme];
    }

    function tokenBenefits(uint256 tokenId) external view returns (BenefitConfig memory) {
        if (_owners[tokenId] == address(0)) revert TokenNotMinted(tokenId);
        return _themeBenefits[tokenTheme(tokenId)];
    }

    function benefitOf(address user) public view returns (BenefitConfig memory) {
        uint256 tokenId = _activeBenefitToken[user];
        if (tokenId == 0 || _owners[tokenId] != user) {
            return BenefitConfig(0, 0, 0, 0, 0, 0, 0, false, false);
        }
        return _themeBenefits[tokenTheme(tokenId)];
    }

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
        )
    {
        BenefitConfig memory config = benefitOf(user);
        return (
            config.tradingFeeDiscountBps,
            config.tokenAirdropBonusBps,
            config.insurancePremiumDiscountBps,
            config.liquidationProtectionBoostBps,
            config.tradingCompetitionBoostBps,
            config.lpYieldBoostBps,
            config.lpExitCooldownReductionBps,
            config.partnerWhitelistEligible,
            config.priorityAccessEligible
        );
    }

    function tradingFeeDiscountOf(address user) external view returns (uint16) {
        return benefitOf(user).tradingFeeDiscountBps;
    }

    function insuranceBenefitAdjustmentsOf(address user)
        external
        view
        returns (uint16 premiumDiscountBps, uint16 liquidationProtectionBoostBps)
    {
        BenefitConfig memory config = benefitOf(user);
        return (config.insurancePremiumDiscountBps, config.liquidationProtectionBoostBps);
    }

    function liquidityBenefitAdjustmentsOf(address user)
        external
        view
        returns (uint16 lpYieldBoostBps, uint16 lpExitCooldownReductionBps)
    {
        BenefitConfig memory config = benefitOf(user);
        return (config.lpYieldBoostBps, config.lpExitCooldownReductionBps);
    }

    function isPartnerWhitelistEligible(address user) external view returns (bool) {
        return benefitOf(user).partnerWhitelistEligible;
    }

    function hasPriorityAccess(address user) external view returns (bool) {
        return benefitOf(user).priorityAccessEligible;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_owners[tokenId] == address(0)) revert TokenNotMinted(tokenId);
        return string.concat(_baseTokenURI, _toString(tokenId), _uriSuffix);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        if (_owners[tokenId] == address(0)) revert TokenNotMinted(tokenId);
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address owner_, address operator) external view returns (bool) {
        return _operatorApprovals[owner_][operator];
    }

    function approve(address to, uint256 tokenId) external {
        address owner_ = ownerOf(tokenId);
        if (msg.sender != owner_ && !_operatorApprovals[owner_][msg.sender]) {
            revert NotAuthorized(msg.sender, tokenId);
        }
        _tokenApprovals[tokenId] = to;
        emit Approval(owner_, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        _transfer(from, to, tokenId);
        if (!_checkOnERC721Received(from, to, tokenId, data)) {
            revert TransferToNonReceiver();
        }
    }

    function assignRecipients(address[] calldata recipients, uint256[] calldata tokenIds) external onlyOwner {
        uint256 length = tokenIds.length;
        if (recipients.length != length) revert AssignmentLengthMismatch();

        for (uint256 i = 0; i < length; ++i) {
            _setAssignment(tokenIds[i], recipients[i], false);
        }
    }

    function reassignRecipient(uint256 tokenId, address newRecipient) external onlyOwner {
        _setAssignment(tokenId, newRecipient, true);
    }

    function clearAssignment(uint256 tokenId) external onlyOwner {
        _requireValidTokenId(tokenId);
        if (_owners[tokenId] != address(0)) revert TokenAlreadyMinted(tokenId);
        delete _assignedRecipient[tokenId];
        emit ClaimAssignmentUpdated(tokenId, address(0));
    }

    function claim(uint256 tokenId) external {
        _claim(tokenId, msg.sender);
    }

    function claimBatch(uint256[] calldata tokenIds) external {
        uint256 length = tokenIds.length;
        for (uint256 i = 0; i < length; ++i) {
            _claim(tokenIds[i], msg.sender);
        }
    }

    function adminMint(address to, uint256 tokenId) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        _mint(to, tokenId);
    }

    function setBaseTokenURI(string calldata newBaseTokenURI, string calldata newSuffix) external onlyOwner {
        _baseTokenURI = newBaseTokenURI;
        _uriSuffix = newSuffix;
        emit BaseTokenURIUpdated(newBaseTokenURI, newSuffix);
    }

    function setActiveBenefitToken(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotAuthorized(msg.sender, tokenId);
        _setActiveBenefitToken(msg.sender, tokenId);
    }

    function clearActiveBenefitToken() external {
        _clearActiveBenefitToken(msg.sender);
    }

    function setThemeBenefits(Theme theme, BenefitConfig calldata config) external onlyOwner {
        _validateBenefits(config);
        _themeBenefits[theme] = config;

        emit ThemeBenefitsUpdated(
            theme,
            config.tradingFeeDiscountBps,
            config.tokenAirdropBonusBps,
            config.insurancePremiumDiscountBps,
            config.liquidationProtectionBoostBps,
            config.tradingCompetitionBoostBps,
            config.lpYieldBoostBps,
            config.lpExitCooldownReductionBps,
            config.partnerWhitelistEligible,
            config.priorityAccessEligible
        );
    }

    function _claim(uint256 tokenId, address claimer) internal {
        _requireValidTokenId(tokenId);
        if (_owners[tokenId] != address(0)) revert TokenAlreadyMinted(tokenId);
        if (_assignedRecipient[tokenId] != claimer) revert NotAssignedRecipient(tokenId, claimer);

        delete _assignedRecipient[tokenId];
        _mint(claimer, tokenId);

        emit TokenClaimed(claimer, tokenId, tokenTheme(tokenId));
    }

    function _mint(address to, uint256 tokenId) internal {
        _requireValidTokenId(tokenId);
        if (to == address(0)) revert InvalidAddress();
        if (_owners[tokenId] != address(0)) revert TokenAlreadyMinted(tokenId);

        unchecked {
            _balances[to] += 1;
            _totalMinted += 1;
        }
        _owners[tokenId] = to;
        if (_activeBenefitToken[to] == 0) {
            _activeBenefitToken[to] = tokenId;
            emit ActiveBenefitTokenUpdated(to, tokenId);
        }

        emit Transfer(address(0), to, tokenId);
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        if (to == address(0)) revert InvalidAddress();

        address owner_ = ownerOf(tokenId);
        if (owner_ != from) revert NotAuthorized(msg.sender, tokenId);

        bool approved = msg.sender == owner_ || _operatorApprovals[owner_][msg.sender]
            || _tokenApprovals[tokenId] == msg.sender;
        if (!approved) revert NotAuthorized(msg.sender, tokenId);

        delete _tokenApprovals[tokenId];

        unchecked {
            _balances[from] -= 1;
            _balances[to] += 1;
        }
        _owners[tokenId] = to;
        if (_activeBenefitToken[from] == tokenId) {
            delete _activeBenefitToken[from];
            emit ActiveBenefitTokenUpdated(from, 0);
        }
        if (_activeBenefitToken[to] == 0) {
            _activeBenefitToken[to] = tokenId;
            emit ActiveBenefitTokenUpdated(to, tokenId);
        }

        emit Approval(from, address(0), tokenId);
        emit Transfer(from, to, tokenId);
    }

    function _setAssignment(uint256 tokenId, address recipient, bool overwrite) internal {
        _requireValidTokenId(tokenId);
        if (recipient == address(0)) revert InvalidAddress();
        if (_owners[tokenId] != address(0)) revert TokenAlreadyMinted(tokenId);

        address currentAssignee = _assignedRecipient[tokenId];
        if (!overwrite && currentAssignee != address(0)) {
            revert TokenAlreadyAssigned(tokenId, currentAssignee);
        }

        _assignedRecipient[tokenId] = recipient;
        emit ClaimAssignmentUpdated(tokenId, recipient);
    }

    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data)
        private
        returns (bool)
    {
        if (to.code.length == 0) {
            return true;
        }

        try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 retval) {
            return retval == IERC721Receiver.onERC721Received.selector;
        } catch {
            return false;
        }
    }

    function _requireValidTokenId(uint256 tokenId) internal pure {
        if (tokenId == 0 || tokenId > MAX_SUPPLY) revert InvalidTokenId(tokenId);
    }

    function _setActiveBenefitToken(address user, uint256 tokenId) internal {
        _activeBenefitToken[user] = tokenId;
        emit ActiveBenefitTokenUpdated(user, tokenId);
    }

    function _clearActiveBenefitToken(address user) internal {
        if (_activeBenefitToken[user] != 0) {
            delete _activeBenefitToken[user];
            emit ActiveBenefitTokenUpdated(user, 0);
        }
    }

    function _validateBenefits(BenefitConfig calldata config) internal pure {
        if (config.tradingFeeDiscountBps > 10_000) revert InvalidBpsValue(config.tradingFeeDiscountBps);
        if (config.tokenAirdropBonusBps > 10_000) revert InvalidBpsValue(config.tokenAirdropBonusBps);
        if (config.insurancePremiumDiscountBps > 10_000) {
            revert InvalidBpsValue(config.insurancePremiumDiscountBps);
        }
        if (config.liquidationProtectionBoostBps > 10_000) {
            revert InvalidBpsValue(config.liquidationProtectionBoostBps);
        }
        if (config.tradingCompetitionBoostBps > 10_000) {
            revert InvalidBpsValue(config.tradingCompetitionBoostBps);
        }
        if (config.lpYieldBoostBps > 10_000) {
            revert InvalidBpsValue(config.lpYieldBoostBps);
        }
        if (config.lpExitCooldownReductionBps > 10_000) {
            revert InvalidBpsValue(config.lpExitCooldownReductionBps);
        }
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            unchecked {
                ++digits;
            }
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
