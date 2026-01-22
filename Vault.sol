// SPDX-License-Identifier: LGPL-3.0
pragma solidity 0.8.30;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {SafeERC20, IERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {ERC20Permit, ERC20} from '@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol';
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IVault} from './IVault.sol';
import {Errors} from './Errors.sol';

/**
 * @title RWA Zero-Balance Vault
 * @notice An ERC4626-compliant vault designed for Real World Assets (RWA). 
 * @author Gemini Thought Partner
 * @dev Key characteristics:
 * 1. Zero-Balance: Assets are moved off-chain to a custody wallet immediately.
 * 2. Manual Pricing: NAV is updated by the Investment Manager via a virtual ledger.
 * 3. Async Redemption: Shares are locked for a period before being processed for off-chain liquidation.
 * 4. Slippage Protection: Users define minimum assets expected during the redemption request.
 */
contract Vault is AccessControl, ReentrancyGuard, ERC20Permit, ERC4626, IVault {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // -------------------------------------------------------------------------
    // Roles & Constants
    // -------------------------------------------------------------------------
    
    /** @notice Authorized to set share prices, manage pool limits, and freeze accounts. */
    bytes32 private constant INVESTMENT_MANAGER_ROLE = keccak256('INVESTMENT_MANAGER_ROLE');
    
    /** @notice Role assigned to restricted accounts to block all transfers and redemptions. */
    bytes32 private constant BLACKLISTED_ROLE = keccak256('BLACKLISTED_ROLE');

    /** @dev Minimum shares threshold to prevent vault inflation/rounding attacks. */
    uint256 private constant MIN_SHARES = 1e6;

    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    /** @notice Decimals of the underlying asset token. */
    uint8 private immutable _assetDecimals;

    /** @notice Address of the off-chain custody wallet for asset deposits. */
    address public custodyWallet;
    
    /** @notice Virtual ledger tracking the total assets value managed by the vault. */
    uint256 private _manualTotalAssets;

    /** @notice Maximum total assets the vault is allowed to manage. */
    uint256 private _maxPoolDeposit;

    /** @notice The price of 1.0 share in asset units used when totalSupply is zero. */
    uint256 private _initialPrice;

    /** @notice Switch to globally pause new deposits. */
    bool private _pausedDeposit;

    /** @notice Switch to globally pause the fulfillment of redemptions. */
    bool private _pausedWithdraw;

    /** * @dev Data structure for pending redemption requests. */
    struct RedeemRequest {
        uint256 shares;    // Shares locked in the contract
        uint256 minAssets; // Minimum assets the user expects (Slippage protection)
        uint64 createdAt;  // Timestamp of the request
    }
    
    /** @dev Mapping from user address to their active redemption request. */
    mapping(address => RedeemRequest) private _redeemRequests;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @param _asset The address of the underlying ERC20 token.
     * @param _name Name of the vault share token.
     * @param _symbol Symbol of the vault share token.
     * @param _initialAdmin Address granted Admin and Investment Manager roles.
     * @param _custodyWallet Off-chain wallet address for asset custody.
     * @param _initPrice Initial price of 1.0 share (e.g., 1e6 for 1.0 USDC).
     */
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _initialAdmin,
        address _custodyWallet,
        uint256 _initPrice
    )
        ERC20(_name, _symbol)
        ERC4626(_asset)
        ERC20Permit(_name)
    {
        require(_custodyWallet != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
        require(_initialAdmin != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
        require(_initPrice > 0, "Vault: init price must be > 0");

        _assetDecimals = IERC20Metadata(address(_asset)).decimals();
        _maxPoolDeposit = type(uint256).max;
        custodyWallet = _custodyWallet;
        _initialPrice = _initPrice;

        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(INVESTMENT_MANAGER_ROLE, _initialAdmin);
    }

    // -------------------------------------------------------------------------
    // Manual Pricing Logic
    // -------------------------------------------------------------------------

    /**
     * @notice Updates the share price and recalculates the internal virtual ledger.
     * @dev If supply > 0, updates _manualTotalAssets. If supply == 0, updates _initialPrice.
     * @param newPrice The new price of 1.0 share in asset units.
     */
    function setSharePrice(uint256 newPrice) external onlyRole(INVESTMENT_MANAGER_ROLE) {
        require(newPrice > 0, "Vault: price must be > 0");
        uint256 supply = totalSupply();
        uint256 oldPrice = getSharePrice();

        if (supply > 0) {
            _manualTotalAssets = supply.mulDiv(newPrice, 10 ** _assetDecimals, Math.Rounding.Floor);
        } else {
            _initialPrice = newPrice;
        }
        
        emit SharePriceUpdated(oldPrice, newPrice);
        emit ExternalBookValueUpdated(0, _manualTotalAssets, 0);
    }

    /**
     * @notice Returns the current price of 1.0 share based on the manual ledger.
     * @return Price of 1.0 share in underlying asset units.
     */
    function getSharePrice() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return _initialPrice;
        return _manualTotalAssets.mulDiv(10 ** _assetDecimals, supply, Math.Rounding.Floor);
    }

    /**
     * @notice Returns the total managed assets value from the virtual ledger.
     * @dev Overrides totalAssets from both ERC4626 and IERC4626 interfaces.
     */
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return _manualTotalAssets;
    }

    // -------------------------------------------------------------------------
    // ERC4626 Internal Overrides
    // -------------------------------------------------------------------------

    /** @dev Internal logic for converting assets to shares, applying initial price when supply is zero. */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return assets.mulDiv(10 ** _assetDecimals, _initialPrice, rounding);
        }
        return assets.mulDiv(supply, _manualTotalAssets, rounding);
    }

    /** @dev Internal logic for converting shares to assets, applying initial price when supply is zero. */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return shares.mulDiv(_initialPrice, 10 ** _assetDecimals, rounding);
        }
        return shares.mulDiv(_manualTotalAssets, supply, rounding);
    }

    // -------------------------------------------------------------------------
    // Deposit & Redemption Flow
    // -------------------------------------------------------------------------

    /**
     * @dev Internal deposit implementation sending capital directly to custody wallet.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (_pausedDeposit) revert(Errors.DEPOSIT_OPERATION_PAUSED);
        require(assets > 0 && shares > 0, Errors.ZERO_AMOUNT_NOT_VALID);
        if (_manualTotalAssets + assets > _maxPoolDeposit) revert(Errors.STAKE_LIMIT_EXCEEDED);

        IERC20(asset()).safeTransferFrom(caller, custodyWallet, assets);
        
        _manualTotalAssets += assets;

        _mint(receiver, shares);
        _checkMinShares();
        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @notice Fulfills a user's pending redemption request.
     * @dev Must be called by the custodyWallet. Assets are pulled from custodyWallet.
     * @param user The address of the shareholder being fulfilled.
     */
    function processRedeem(address user) external override nonReentrant {
        require(_msgSender() == custodyWallet, Errors.OPERATION_NOT_ALLOWED);
        if (_pausedWithdraw) revert(Errors.WITHDRAW_OPERATION_PAUSED);
        
        RedeemRequest memory r = _redeemRequests[user];
        require(r.shares > 0, Errors.INVALID_AMOUNT);
        if (hasRole(BLACKLISTED_ROLE, user)) revert(Errors.OPERATION_NOT_ALLOWED);

        uint256 currentAssets = convertToAssets(r.shares);
        if (currentAssets < r.minAssets) revert("Vault: slippage too high");
        
        IERC20(asset()).safeTransferFrom(custodyWallet, user, currentAssets);

        _manualTotalAssets = _manualTotalAssets > currentAssets ? _manualTotalAssets - currentAssets : 0;

        _burn(address(this), r.shares);
        delete _redeemRequests[user];
        _checkMinShares();
        
        emit RedeemFinalized(user, r.shares, currentAssets);
    }

    /**
     * @notice Initiates a redemption request by locking shares in the contract.
     * @param shares Amount of shares to lock.
     * @param minAssetsOut Minimum assets the user expects (Slippage protection).
     */
    function requestRedeem(uint256 shares, uint256 minAssetsOut) external override nonReentrant {
        if (hasRole(BLACKLISTED_ROLE, _msgSender())) revert(Errors.OPERATION_NOT_ALLOWED);
        require(balanceOf(_msgSender()) >= shares, Errors.INVALID_AMOUNT);
        require(_redeemRequests[_msgSender()].shares == 0, "Vault: existing request pending");

        _transfer(_msgSender(), address(this), shares);
        _redeemRequests[_msgSender()] = RedeemRequest({ 
            shares: shares, 
            minAssets: minAssetsOut,
            createdAt: uint64(block.timestamp) 
        });

        emit RedeemRequested(_msgSender(), shares, minAssetsOut);
    }

    /**
     * @notice Reclaims shares from a pending redemption and cancels the process.
     */
    function cancelRedeemRequest() external override nonReentrant {
        RedeemRequest memory r = _redeemRequests[_msgSender()];
        require(r.shares > 0, Errors.INVALID_AMOUNT);

        uint256 sharesToReturn = r.shares;
        delete _redeemRequests[_msgSender()];
        
        _transfer(address(this), _msgSender(), sharesToReturn);
        emit RedeemCancelled(_msgSender());
    }

    // -------------------------------------------------------------------------
    // Compliance & Admin Functions
    // -------------------------------------------------------------------------

    /** @notice Adds an account to the blacklist. */
    function freezeAccount(address user) external onlyRole(INVESTMENT_MANAGER_ROLE) {
        _grantRole(BLACKLISTED_ROLE, user);
        emit AccountFrozen(user);
    }

    /** @notice Removes an account from the blacklist. */
    function unfreezeAccount(address user) external onlyRole(INVESTMENT_MANAGER_ROLE) {
        _revokeRole(BLACKLISTED_ROLE, user);
        emit AccountUnfrozen(user);
    }

    /** * @notice Forcibly transfers shares and pending requests for legal compliance.
     * @param from Account to move assets from.
     * @param to Account to move assets to.
     */
    function forceTransfer(address from, address to) external onlyRole(INVESTMENT_MANAGER_ROLE) {
        uint256 bal = balanceOf(from);
        if (bal > 0) _transfer(from, to, bal);
        
        RedeemRequest memory r = _redeemRequests[from];
        if (r.shares > 0) {
            delete _redeemRequests[from];
            _transfer(address(this), to, r.shares);
        }
        emit ForceTransfer(from, to, bal + r.shares);
    }

    /** @notice Updates the off-chain custody wallet address. */
    function setCustodyWallet(address _custody) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_custody != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
        emit CustodyWalletUpdated(custodyWallet, _custody);
        custodyWallet = _custody;
    }

    /** @notice Sets the maximum deposit limit of the pool. */
    function configPoolLimit(uint256 _limit) external onlyRole(DEFAULT_ADMIN_ROLE) { 
        emit ConfigPoolLimit(_maxPoolDeposit, _limit);
        _maxPoolDeposit = _limit; 
    }
    
    /** @notice Pauses/Unpauses operations. */
    function pauseDeposit() external onlyRole(DEFAULT_ADMIN_ROLE) { _pausedDeposit = true; emit PausedDeposit(_msgSender()); }
    function unpauseDeposit() external onlyRole(DEFAULT_ADMIN_ROLE) { _pausedDeposit = false; emit UnpausedDeposit(_msgSender()); }
    function pauseWithdraw() external onlyRole(DEFAULT_ADMIN_ROLE) { _pausedWithdraw = true; emit PausedWithdraw(_msgSender()); }
    function unpauseWithdraw() external onlyRole(DEFAULT_ADMIN_ROLE) { _pausedWithdraw = false; emit UnpausedWithdraw(_msgSender()); }

    /** @notice Rescues accidentally sent ERC20 tokens (excluding underlying asset). */
    function rescueTokens(address token, uint256 amount, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).safeTransfer(to, amount);
    }

    // -------------------------------------------------------------------------
    // View Helpers
    // -------------------------------------------------------------------------

    /** @notice Returns decimals. Overrides ERC4626, ERC20, and IERC20Metadata. */
    function decimals() public view override(ERC4626, ERC20, IERC20Metadata) returns (uint8) { 
        return _assetDecimals; 
    }

    /** @notice Returns user balance, estimated asset value, and locked shares. */
    function userPosition(address user) external view override returns (uint256 shares, uint256 estimatedAssets, uint256 lockedShares) {
        shares = balanceOf(user);
        estimatedAssets = convertToAssets(shares);
        lockedShares = _redeemRequests[user].shares;
    }

    /** @notice Returns details of a user's redemption request. */
    function redeemRequests(address user) external view override returns (uint256 shares, uint256 minAssetsOut, uint64 createdAt) {
        RedeemRequest memory r = _redeemRequests[user];
        return (r.shares, r.minAssets, r.createdAt);
    }

    /** @notice Checks if an address is blacklisted. */
    function isBlacklist(address _a) public view override returns (bool) { return hasRole(BLACKLISTED_ROLE, _a); }
    
    /** @notice Checks if an address is an Investment Manager. */
    function isInvestmentManager(address _a) external view override returns (bool) { return hasRole(INVESTMENT_MANAGER_ROLE, _a); }

    /** @dev Prevents inflation attacks via a minimum shares threshold. */
    function _checkMinShares() internal view {
        uint256 ts = totalSupply();
        if (ts > 0 && ts < MIN_SHARES) revert(Errors.MIN_SHARES_VIOLATION);
    }

    /** @dev Compliance hook: Filters transfers based on blacklist status. */
    function _update(address from, address to, uint256 val) internal override {
        if (from != address(0) && hasRole(BLACKLISTED_ROLE, from) && !hasRole(INVESTMENT_MANAGER_ROLE, _msgSender())) {
            revert(Errors.OPERATION_NOT_ALLOWED);
        }
        if (to != address(0) && hasRole(BLACKLISTED_ROLE, to) && !hasRole(INVESTMENT_MANAGER_ROLE, _msgSender())) {
            revert(Errors.OPERATION_NOT_ALLOWED);
        }
        super._update(from, to, val);
    }

    // -------------------------------------------------------------------------
    // Disabled Standard ERC4626 Sync Methods
    // -------------------------------------------------------------------------
    
    /** @dev Synchronous withdraw is disabled to enforce async redemption flow. Overrides ERC4626 & IERC4626. */
    function withdraw(uint256, address, address) public pure override(ERC4626, IERC4626) returns (uint256) { revert(Errors.OPERATION_NOT_ALLOWED); }
    /** @dev Synchronous redeem is disabled to enforce async redemption flow. Overrides ERC4626 & IERC4626. */
    function redeem(uint256, address, address) public pure override(ERC4626, IERC4626) returns (uint256) { revert(Errors.OPERATION_NOT_ALLOWED); }
}