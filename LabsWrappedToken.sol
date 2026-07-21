// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface ILabsWrapperVaultView {
    function wrappedToken() external view returns (address);
    function officialToken() external view returns (address);
}

/// @title LABS wrapped product token
/// @notice ERC20 representation of locked official product token backing, for example uLAI.
/// @dev Transfers are intentionally unrestricted. Mint and burn are controlled by LabsWrapperVault roles.
contract LabsWrappedToken is ERC20, ERC20Permit, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    uint8 private immutable tokenDecimals;
    address public immutable officialToken;
    address public vault;

    event WrappedMinted(address indexed to, uint256 amount, address indexed operator);
    event WrappedBurned(address indexed from, uint256 amount, address indexed operator);
    event VaultBound(address indexed vault);

    constructor(
        string memory name_,
        string memory symbol_,
        address officialToken_,
        address admin
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        require(officialToken_ != address(0), "official_zero");
        require(officialToken_.code.length > 0, "official_not_contract");
        require(admin != address(0), "admin_zero");
        tokenDecimals = IERC20Metadata(officialToken_).decimals();
        officialToken = officialToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(to != address(0), "to_zero");
        require(amount > 0, "amount_zero");
        _mint(to, amount);
        emit WrappedMinted(to, amount, msg.sender);
    }

    /// @notice Burn from a holder after allowance is granted to the caller.
    function burnFrom(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        require(from != address(0), "from_zero");
        require(amount > 0, "amount_zero");
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
        emit WrappedBurned(from, amount, msg.sender);
    }

    /// @notice Bind the single LabsWrapperVault allowed to mint and burn this token.
    /// @dev One-time operation after vault deployment. Admin can still revoke roles for emergency stop,
    ///      but cannot grant mint/burn roles to any address other than the bound vault.
    function bindVault(address vault_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(vault == address(0), "vault_already_bound");
        require(vault_ != address(0), "vault_zero");
        require(vault_.code.length > 0, "vault_not_contract");
        require(ILabsWrapperVaultView(vault_).wrappedToken() == address(this), "vault_token_mismatch");
        require(ILabsWrapperVaultView(vault_).officialToken() == officialToken, "vault_official_mismatch");
        require(balanceOf(vault_) == 0, "vault_holds_wrapped");
        vault = vault_;
        _grantRole(MINTER_ROLE, vault_);
        _grantRole(BURNER_ROLE, vault_);
        emit VaultBound(vault_);
    }

    function grantRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (role == MINTER_ROLE || role == BURNER_ROLE) {
            require(vault != address(0), "vault_not_bound");
            require(account == vault, "role_restricted_to_vault");
        }
        super.grantRole(role, account);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0) && to == vault) {
            revert("transfer_to_vault_blocked");
        }
        super._update(from, to, value);
    }
}
