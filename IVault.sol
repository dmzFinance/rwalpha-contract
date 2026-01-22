// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IVault
 * @notice Interface for a Real World Asset (RWA) Vault using manual pricing and asynchronous redemptions.
 * @dev This interface defines the administrative, compliance, and user-facing functions 
 * for a vault where assets are held in an off-chain custody wallet.
 * * Includes enhanced support for slippage protection in the asynchronous redemption flow.
 */
interface IVault is IERC4626 {
    
    // =========================================================================
    // Events
    // =========================================================================
    
    /** @notice Emitted when the exchange rate (price) of shares to assets is manually updated. */
    event SharePriceUpdated(uint256 oldPrice, uint256 newPrice);
    
    /** @notice Emitted when the maximum deposit capacity of the vault is changed. */
    event ConfigPoolLimit(uint256 oldLimit, uint256 newLimit);
    
    /** @notice Emitted when the deposit functionality is paused. */
    event PausedDeposit(address account);
    
    /** @notice Emitted when the deposit functionality is resumed. */
    event UnpausedDeposit(address account);
    
    /** @notice Emitted when withdrawal/redemption processing is paused. */
    event PausedWithdraw(address account);
    
    /** @notice Emitted when withdrawal/redemption processing is resumed. */
    event UnpausedWithdraw(address account);

    /** @notice Emitted when the destination address for off-chain deposits is updated. */
    event CustodyWalletUpdated(address indexed prev, address indexed cur);
    
    /** @notice Emitted when the manual internal ledger (Total Assets) is adjusted. */
    event ExternalBookValueUpdated(uint256 oldVal, uint256 newVal, uint256 nonce);

    /** * @notice Emitted when a user locks shares to request a redemption. 
     * @param user The address of the user making the request.
     * @param shares The amount of shares locked in the vault.
     * @param minAssetsOut The minimum amount of assets the user expects (slippage protection).
     */
    event RedeemRequested(address indexed user, uint256 shares, uint256 minAssetsOut);
    
    /** @notice Emitted when a user cancels their pending redemption request. */
    event RedeemCancelled(address indexed user);
    
    /** * @notice Emitted when the custody wallet fulfills a redemption and burns the shares. 
     * @param user The user receiving the assets.
     * @param sharesBurned The amount of shares destroyed.
     * @param assetsReceived The actual amount of underlying assets sent to the user.
     */
    event RedeemFinalized(address indexed user, uint256 sharesBurned, uint256 assetsReceived);

    /** @notice Emitted when an account is added to the blacklist. */
    event AccountFrozen(address indexed user);
    
    /** @notice Emitted when an account is removed from the blacklist. */
    event AccountUnfrozen(address indexed user);
    
    /** @notice Emitted when assets are forcibly moved between accounts for compliance reasons. */
    event ForceTransfer(address indexed from, address indexed to, uint256 amount);
    
    // =========================================================================
    // User & Investment Manager Functions
    // =========================================================================

    /**
     * @notice Manually updates the share price by recalculating total assets based on a new valuation.
     * @dev Only callable by INVESTMENT_MANAGER_ROLE.
     * @param newPrice The value of 1.0 share in underlying assets (scaled by asset decimals).
     */
    function setSharePrice(uint256 newPrice) external;

    /**
     * @notice Returns the current asset value for a single share based on the manual ledger.
     * @return The amount of assets 1.0 share is currently worth.
     */
    function getSharePrice() external view returns (uint256);

    /**
     * @notice Transfers shares from the user to the contract to begin the asynchronous redemption process.
     * @dev Sets a slippage floor to protect against price drops before the request is processed.
     * @param shares The amount of shares to lock for redemption.
     * @param minAssetsOut The minimum amount of underlying assets the user accepts.
     */
    function requestRedeem(uint256 shares, uint256 minAssetsOut) external;

    /**
     * @notice Reclaims shares from a pending redemption request and cancels the process.
     * @dev Only the user who made the request can cancel it.
     */
    function cancelRedeemRequest() external;

    /**
     * @notice Finalizes a redemption request by transferring assets and burning shares. 
     * @dev Only callable by the custodyWallet. Assets are pulled from the custodyWallet via safeTransferFrom.
     * @param user The address of the user who requested the redemption.
     */
    function processRedeem(address user) external;
    
    /**
     * @notice Returns details for a user's active redemption request.
     * @param user The address of the shareholder.
     * @return shares The amount of shares locked.
     * @return minAssetsOut The minimum asset threshold set by the user.
     * @return createdAt The timestamp when the request was made.
     */
    function redeemRequests(address user) external view returns (uint256 shares, uint256 minAssetsOut, uint64 createdAt);

    /**
     * @notice Helper to return a user's total shares, estimated asset value, and locked shares.
     * @param user The address of the user to query.
     * @return shares Unlocked share balance.
     * @return estimatedAssets Estimated value of current unlocked shares.
     * @return lockedShares Shares currently held in a pending redemption request.
     */
    function userPosition(address user) external view returns (
        uint256 shares,
        uint256 estimatedAssets,
        uint256 lockedShares
    );

    // =========================================================================
    // Administrative & Compliance Functions
    // =========================================================================

    /** @notice Sets a new off-chain custody wallet address for deposit redirection. */
    function setCustodyWallet(address _custody) external;

    /** @notice Updates the maximum asset capacity (cap) of the vault. */
    function configPoolLimit(uint256 _poolDepositLimit) external;

    /** @notice Pauses new deposits from users. */
    function pauseDeposit() external;

    /** @notice Unpauses new deposits. */
    function unpauseDeposit() external;

    /** @notice Pauses the ability to finalize redemptions. */
    function pauseWithdraw() external;

    /** @notice Unpauses the ability to finalize redemptions. */
    function unpauseWithdraw() external;
    
    /** * @notice Rescues accidentally sent ERC20 tokens.
     * @dev Cannot rescue the underlying asset token.
     */
    function rescueTokens(address token, uint256 amount, address to) external;

    /** @notice Prevents a user from transferring shares or requesting redemptions. */
    function freezeAccount(address user) external;

    /** @notice Removes a user from the blacklist. */
    function unfreezeAccount(address user) external;

    /** * @notice Forcibly moves shares and pending requests from one address to another.
     * @dev Used for legal compliance, court orders, or inheritance.
     */
    function forceTransfer(address from, address to) external;

    /** @notice Returns true if the address is currently blacklisted. */
    function isBlacklist(address _address) external view returns (bool);

    /** @notice Returns true if the address holds the Investment Manager role. */
    function isInvestmentManager(address _addr) external view returns (bool);
}