// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "../vendor/openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "../vendor/openzeppelin/contracts/access/Ownable2Step.sol";
import {Errors} from "../libraries/Errors.sol";
import {Events} from "../libraries/Events.sol";
import {IMarginVault} from "../interfaces/IMarginVault.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title MarginVault
/// @notice Custodies collateral balances and margin locks for the perpetual protocol.
/// @dev Supports a single collateral token in MVP mode.
contract MarginVault is Ownable2Step, IMarginVault {
    error TransferFailed();

    address public immutable collateralToken;

    mapping(address user => uint256 amount) public totalBalance;
    mapping(address user => uint256 amount) public lockedMargin;
    mapping(address module => bool isAuthorized) public authorizedModules;

    event ModuleAuthorizationUpdated(address indexed module, bool isAuthorized);

    /// @notice Deploys MarginVault with an owner and collateral token.
    /// @param initialOwner Governance owner allowed to manage authorized modules.
    /// @param collateralToken_ ERC20 collateral token used by the protocol.
    constructor(address initialOwner, address collateralToken_) Ownable(initialOwner) {
        if (collateralToken_ == address(0)) revert Errors.InvalidAddress();
        collateralToken = collateralToken_;
    }

    modifier onlyAuthorizedModule() {
        if (!authorizedModules[msg.sender]) revert Errors.Unauthorized();
        _;
    }

    /// @notice Updates whether a protocol module can lock/unlock and transfer settlement funds.
    /// @param module Module address to authorize or revoke.
    /// @param isAuthorized True to authorize, false to revoke.
    function setAuthorizedModule(address module, bool isAuthorized) external onlyOwner {
        if (module == address(0)) revert Errors.InvalidAddress();
        authorizedModules[module] = isAuthorized;
        emit ModuleAuthorizationUpdated(module, isAuthorized);
    }

    /// @notice Deposits collateral into the vault for the caller.
    /// @param amount Collateral amount to deposit.
    function deposit(uint256 amount) external override {
        if (amount == 0) revert Errors.ZeroAmount();
        _safeTransferFrom(collateralToken, msg.sender, address(this), amount);
        totalBalance[msg.sender] += amount;
        emit Events.Deposited(msg.sender, collateralToken, amount);
    }

    /// @notice Withdraws available (unlocked) collateral for the caller.
    /// @param amount Collateral amount to withdraw.
    function withdraw(uint256 amount) external override {
        _transferOut(msg.sender, amount);
    }

    /// @notice Transfers available collateral out on behalf of a user.
    /// @dev Intended for withdrawal workflows coordinated by authorized modules.
    /// @param user User whose vault balance is reduced.
    /// @param amount Collateral amount to transfer.
    function transferOut(address user, uint256 amount) external override onlyAuthorizedModule {
        _transferOut(user, amount);
    }

    /// @notice Locks a user's available balance as margin.
    /// @param user Account whose margin is locked.
    /// @param amount Amount of margin to lock.
    function lockMargin(address user, uint256 amount) external override onlyAuthorizedModule {
        if (user == address(0)) revert Errors.InvalidAddress();
        if (amount == 0) revert Errors.ZeroAmount();
        uint256 available = totalBalance[user] - lockedMargin[user];
        if (available < amount) revert Errors.InsufficientMargin();
        lockedMargin[user] += amount;
        emit Events.MarginLocked(user, amount, lockedMargin[user]);
    }

    /// @notice Unlocks previously locked margin for a user.
    /// @param user Account whose margin is unlocked.
    /// @param amount Amount of margin to unlock.
    function unlockMargin(address user, uint256 amount) external override onlyAuthorizedModule {
        if (user == address(0)) revert Errors.InvalidAddress();
        if (amount == 0) revert Errors.ZeroAmount();
        if (lockedMargin[user] < amount) revert Errors.InsufficientMargin();
        lockedMargin[user] -= amount;
        emit Events.MarginUnlocked(user, amount, lockedMargin[user]);
    }

    /// @notice Sends settlement funds from vault liquidity to a recipient.
    /// @param to Recipient account.
    /// @param amount Amount to transfer.
    function transferSettlement(address to, uint256 amount) external override onlyAuthorizedModule {
        if (to == address(0)) revert Errors.InvalidAddress();
        if (amount == 0) revert Errors.ZeroAmount();
        _safeTransfer(collateralToken, to, amount);
        emit Events.SettlementTransferred(to, collateralToken, amount);
    }

    /// @notice Returns a user's currently available (unlocked) collateral balance.
    /// @param user Account to query.
    /// @return amount Available collateral amount.
    function availableBalance(address user) public view override returns (uint256 amount) {
        return totalBalance[user] - lockedMargin[user];
    }

    function _transferOut(address user, uint256 amount) internal {
        if (user == address(0)) revert Errors.InvalidAddress();
        if (amount == 0) revert Errors.ZeroAmount();
        if (availableBalance(user) < amount) revert Errors.InsufficientMargin();
        totalBalance[user] -= amount;
        _safeTransfer(collateralToken, user, amount);
        emit Events.Withdrawn(user, collateralToken, amount);
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
