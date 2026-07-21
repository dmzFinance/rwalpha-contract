// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ILabsWrappedToken {
    function mint(address to, uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

interface IOfficialFundController {
    function requestMint(uint256 stableAmount) external returns (uint256 requestId);
    function requestBurn(uint256 burnAmount) external returns (uint256 requestId);
    function burnRequests(uint256 requestId) external view returns (
        address user,
        address payoutWallet,
        uint256 burnAmount,
        uint256 payoutAmount,
        uint8 status,
        uint64 createdAt,
        uint64 settledAt,
        bytes32 memo
    );
}

/// @title LABS Wrapper Vault
/// @notice Receives LABS stablecoin deposits, submits official mint requests, locks official backing,
///         and mints/burns the corresponding wrapped token 1:1.
contract LabsWrapperVault is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant MINT_OPERATOR_ROLE = keccak256("MINT_OPERATOR_ROLE");
    bytes32 public constant REDEEM_OPERATOR_ROLE = keccak256("REDEEM_OPERATOR_ROLE");
    bytes32 public constant RECEIPT_MANAGER_ROLE = keccak256("RECEIPT_MANAGER_ROLE");
    bytes32 public constant OFFICIAL_BURN_CONFIRMER_ROLE = keccak256("OFFICIAL_BURN_CONFIRMER_ROLE");
    bytes32 public constant OFFICIAL_MINT_OPERATOR_ROLE = keccak256("OFFICIAL_MINT_OPERATOR_ROLE");
    bytes32 public constant PAYMENT_OPERATOR_ROLE = keccak256("PAYMENT_OPERATOR_ROLE");

    IERC20 public immutable officialToken;
    ILabsWrappedToken public immutable wrappedToken;
    IERC20 public immutable stablecoin;
    IOfficialFundController public immutable officialFundController;

    uint256 public pendingStableDeposits;
    uint256 public pendingOfficialMintStable;
    uint256 public registeredMintableBacking;
    uint256 public accountedLocked;
    uint256 public pendingOfficialBurn;
    uint256 public pendingRedeemStableProceeds;
    uint256 public pendingDividendStableProceeds;

    mapping(bytes32 => bool) public processedRefs;

    enum OfficialMintRequestStatus {
        None,
        Submitted,
        Settled,
        Rejected
    }

    enum RedeemQueueStatus {
        None,
        Queued,
        Confirmed
    }

    struct StableDepositOrder {
        address payer;
        address recipient;
        uint256 amount;
    }

    struct OfficialMintRequest {
        uint256 stableAmount;
        uint256 officialAmount;
        bytes32 submitRefId;
        bytes32 terminalRefId;
        bytes32 evidenceHash;
        OfficialMintRequestStatus status;
    }

    struct RedeemQueue {
        address holder;
        uint256 amount;
        uint256 officialBurnRequestId;
        uint256 payoutAmount;
        bytes32 confirmBatchRefId;
        RedeemQueueStatus status;
    }

    mapping(bytes32 => StableDepositOrder) public stableDepositOrders;
    mapping(uint256 => OfficialMintRequest) public officialMintRequests;
    mapping(bytes32 => RedeemQueue) public redeemQueues;

    event OfficialReceiptRegistered(
        bytes32 indexed refId,
        bytes32 indexed sourceType,
        bytes32 indexed evidenceHash,
        uint256 amount,
        uint256 registeredMintableBackingAfter
    );
    event WrappedMintedAgainstLock(
        bytes32 indexed refId,
        address indexed to,
        uint256 amount,
        uint256 accountedLockedAfter
    );
    event StableDeposited(
        bytes32 indexed refId,
        address indexed payer,
        address indexed recipient,
        uint256 amount,
        uint256 pendingStableDepositsAfter
    );
    event DepositRequested(
        bytes32 indexed requestId,
        address indexed requester,
        address indexed owner,
        address receiver,
        uint256 assets
    );
    event OfficialMintRequested(
        bytes32 indexed refId,
        uint256 indexed officialRequestId,
        uint256 stableAmount,
        uint256 pendingStableDepositsAfter,
        uint256 pendingOfficialMintStableAfter
    );
    event OfficialMintSettlementRegistered(
        bytes32 indexed refId,
        uint256 indexed officialRequestId,
        uint256 stableAmount,
        uint256 officialAmount,
        uint256 pendingOfficialMintStableAfter,
        uint256 registeredMintableBackingAfter
    );
    event OfficialMintRejected(
        bytes32 indexed refId,
        uint256 indexed officialRequestId,
        bytes32 indexed evidenceHash,
        uint256 stableAmount,
        uint256 pendingStableDepositsAfter,
        uint256 pendingOfficialMintStableAfter
    );
    event WrappedBurnedAndOfficialBurnQueued(
        bytes32 indexed refId,
        address indexed from,
        uint256 amount,
        uint256 officialBurnRequestId,
        uint256 accountedLockedAfter,
        uint256 pendingOfficialBurnAfter
    );
    event RedeemRequested(
        bytes32 indexed requestId,
        address indexed requester,
        address indexed owner,
        address receiver,
        uint256 shares,
        uint256 officialBurnRequestId
    );
    event OfficialBurnBatchConfirmed(
        bytes32 indexed batchRefId,
        bytes32 indexed evidenceHash,
        uint256 amount,
        uint256 payoutAmount,
        uint256 queueCount,
        uint256 pendingOfficialBurnAfter,
        uint256 officialBalanceAfter,
        uint256 pendingRedeemStableProceedsAfter
    );
    event RedeemStableProceedsReleased(
        bytes32 indexed refId,
        address indexed to,
        uint256 amount,
        uint256 pendingRedeemStableProceedsAfter
    );
    event DividendStableReceiptRegistered(
        bytes32 indexed claimRef,
        bytes32 indexed evidenceHash,
        uint256 amount,
        uint256 pendingDividendStableProceedsAfter
    );
    event DividendStableProceedsReleased(
        bytes32 indexed refId,
        address indexed to,
        uint256 amount,
        uint256 pendingDividendStableProceedsAfter
    );
    event WithdrawalRequested(
        bytes32 indexed requestId,
        address indexed requester,
        address indexed receiver,
        bytes32 assetId,
        uint256 assets,
        bytes32 sourceType,
        bytes32 sourceRef
    );
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    constructor(
        address officialToken_,
        address wrappedToken_,
        address stablecoin_,
        address officialFundController_,
        address admin,
        address mintOperator,
        address redeemOperator,
        address receiptManager,
        address officialBurnConfirmer,
        address officialMintOperator,
        address paymentOperator
    ) {
        require(officialToken_ != address(0), "official_zero");
        require(wrappedToken_ != address(0), "wrapped_zero");
        require(stablecoin_ != address(0), "stablecoin_zero");
        require(officialFundController_ != address(0), "official_controller_zero");
        require(officialToken_ != wrappedToken_, "token_same");
        require(officialToken_.code.length > 0, "official_not_contract");
        require(wrappedToken_.code.length > 0, "wrapped_not_contract");
        require(stablecoin_.code.length > 0, "stablecoin_not_contract");
        require(officialFundController_.code.length > 0, "official_controller_not_contract");
        require(admin != address(0), "admin_zero");
        require(mintOperator != address(0), "mint_operator_zero");
        require(redeemOperator != address(0), "redeem_operator_zero");
        require(receiptManager != address(0), "receipt_manager_zero");
        require(officialBurnConfirmer != address(0), "official_burn_confirmer_zero");
        require(officialMintOperator != address(0), "official_mint_operator_zero");
        require(paymentOperator != address(0), "payment_operator_zero");
        require(
            IERC20Metadata(officialToken_).decimals() == IERC20Metadata(wrappedToken_).decimals(),
            "decimals_mismatch"
        );

        officialToken = IERC20(officialToken_);
        wrappedToken = ILabsWrappedToken(wrappedToken_);
        stablecoin = IERC20(stablecoin_);
        officialFundController = IOfficialFundController(officialFundController_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINT_OPERATOR_ROLE, mintOperator);
        _grantRole(REDEEM_OPERATOR_ROLE, redeemOperator);
        _grantRole(RECEIPT_MANAGER_ROLE, receiptManager);
        _grantRole(OFFICIAL_BURN_CONFIRMER_ROLE, officialBurnConfirmer);
        _grantRole(OFFICIAL_MINT_OPERATOR_ROLE, officialMintOperator);
        _grantRole(PAYMENT_OPERATOR_ROLE, paymentOperator);
    }

    function classifiedStableBalance() public view returns (uint256) {
        return pendingStableDeposits + pendingRedeemStableProceeds + pendingDividendStableProceeds;
    }

    function unregisteredStableBalance() public view returns (uint256) {
        uint256 balance = stablecoin.balanceOf(address(this));
        uint256 classified = classifiedStableBalance();
        return balance > classified ? balance - classified : 0;
    }

    function classifiedOfficialBacking() public view returns (uint256) {
        return registeredMintableBacking + accountedLocked;
    }

    function unregisteredOfficialBalance() public view returns (uint256) {
        uint256 balance = officialToken.balanceOf(address(this));
        uint256 classified = classifiedOfficialBacking();
        return balance > classified ? balance - classified : 0;
    }

    function backingStatus() external view returns (
        uint256 officialBalance,
        uint256 registeredMintableBacking_,
        uint256 accountedLocked_,
        uint256 wrappedSupply,
        uint256 pendingOfficialBurn_,
        uint256 surplus,
        uint256 deficit
    ) {
        officialBalance = officialToken.balanceOf(address(this));
        registeredMintableBacking_ = registeredMintableBacking;
        accountedLocked_ = accountedLocked;
        wrappedSupply = wrappedToken.totalSupply();
        pendingOfficialBurn_ = pendingOfficialBurn;
        uint256 classified = registeredMintableBacking_ + accountedLocked_;
        surplus = officialBalance > classified ? officialBalance - classified : 0;
        deficit = classified > officialBalance ? classified - officialBalance : 0;
    }

    /// @notice Pull stablecoin into this vault for a LABS subscribe order.
    /// @dev Direct ERC20 transfers to the vault are not treated as subscription deposits.
    function depositStable(
        uint256 amount,
        bytes32 refId
    ) external nonReentrant whenNotPaused onlyRole(OFFICIAL_MINT_OPERATOR_ROLE) {
        _depositStableFrom(msg.sender, msg.sender, amount, refId);
    }

    /// @notice User-facing on-chain subscribe request entrypoint.
    /// @dev Pulls stablecoin immediately, then LABS listens to DepositRequested and continues the official flow.
    function requestDeposit(
        uint256 assets,
        address receiver,
        bytes32 requestId
    ) external nonReentrant whenNotPaused {
        _depositStableFrom(msg.sender, receiver, assets, requestId);
        emit DepositRequested(requestId, msg.sender, msg.sender, receiver, assets);
    }

    /// @notice Pull stablecoin into this vault for a LABS subscribe order with explicit business ownership.
    /// @dev The payer must approve this vault before the LABS operator calls this function.
    function depositStableFor(
        address payer,
        address recipient,
        uint256 amount,
        bytes32 refId
    ) external nonReentrant whenNotPaused {
        require(hasRole(OFFICIAL_MINT_OPERATOR_ROLE, msg.sender), "missing_operator_role");
        _depositStableFrom(payer, recipient, amount, refId);
    }

    /// @notice Operator-facing on-chain subscribe request entrypoint for REST/custody mediated orders.
    /// @dev Uses the same DepositRequested event shape as requestDeposit for a unified indexer path.
    function requestDepositFor(
        address owner,
        address receiver,
        uint256 assets,
        bytes32 requestId
    ) external nonReentrant whenNotPaused onlyRole(OFFICIAL_MINT_OPERATOR_ROLE) {
        _depositStableFrom(owner, receiver, assets, requestId);
        emit DepositRequested(requestId, msg.sender, owner, receiver, assets);
    }

    function _depositStableFrom(
        address payer,
        address recipient,
        uint256 amount,
        bytes32 refId
    ) private {
        require(payer != address(0), "payer_zero");
        require(recipient != address(0), "recipient_zero");
        require(amount > 0, "amount_zero");
        _consumeRef(refId);
        stablecoin.safeTransferFrom(payer, address(this), amount);
        stableDepositOrders[refId] = StableDepositOrder({
            payer: payer,
            recipient: recipient,
            amount: amount
        });
        pendingStableDeposits += amount;
        require(stablecoin.balanceOf(address(this)) >= classifiedStableBalance(), "stable_balance_deficit");
        emit StableDeposited(refId, payer, recipient, amount, pendingStableDeposits);
    }

    /// @notice Submit an official FundController requestMint from this vault.
    /// @dev The official request user becomes this vault address. The official system must map this address
    ///      as the LABS institutional wallet for PHP/Admin attribution.
    function submitOfficialMint(
        uint256 stableAmount,
        bytes32 refId
    ) external nonReentrant whenNotPaused onlyRole(OFFICIAL_MINT_OPERATOR_ROLE) returns (uint256 officialRequestId) {
        require(stableAmount > 0, "amount_zero");
        _consumeRef(refId);
        require(pendingStableDeposits >= stableAmount, "insufficient_stable_deposit");

        pendingStableDeposits -= stableAmount;
        pendingOfficialMintStable += stableAmount;
        stablecoin.forceApprove(address(officialFundController), stableAmount);
        officialRequestId = officialFundController.requestMint(stableAmount);
        stablecoin.forceApprove(address(officialFundController), 0);
        require(officialRequestId != 0, "official_request_zero");
        OfficialMintRequest storage request = officialMintRequests[officialRequestId];
        require(request.status == OfficialMintRequestStatus.None, "official_request_exists");
        officialMintRequests[officialRequestId] = OfficialMintRequest({
            stableAmount: stableAmount,
            officialAmount: 0,
            submitRefId: refId,
            terminalRefId: bytes32(0),
            evidenceHash: bytes32(0),
            status: OfficialMintRequestStatus.Submitted
        });
        require(stablecoin.balanceOf(address(this)) >= classifiedStableBalance(), "stable_balance_deficit");

        emit OfficialMintRequested(
            refId,
            officialRequestId,
            stableAmount,
            pendingStableDeposits,
            pendingOfficialMintStable
        );
    }

    /// @notice Register official AI/AIX minted to this vault after the official system settles requestMint.
    function registerOfficialMintSettlement(
        uint256 officialAmount,
        uint256 stableAmount,
        uint256 officialRequestId,
        bytes32 refId
    ) external nonReentrant whenNotPaused onlyRole(RECEIPT_MANAGER_ROLE) {
        require(officialAmount > 0, "official_amount_zero");
        require(stableAmount > 0, "stable_amount_zero");
        _consumeRef(refId);
        OfficialMintRequest storage request = officialMintRequests[officialRequestId];
        require(request.status == OfficialMintRequestStatus.Submitted, "official_request_not_submitted");
        require(request.stableAmount == stableAmount, "official_request_amount_mismatch");
        require(pendingOfficialMintStable >= stableAmount, "insufficient_pending_official_mint");

        pendingOfficialMintStable -= stableAmount;
        registeredMintableBacking += officialAmount;
        require(officialToken.balanceOf(address(this)) >= classifiedOfficialBacking(), "official_balance_deficit");
        request.officialAmount = officialAmount;
        request.terminalRefId = refId;
        request.status = OfficialMintRequestStatus.Settled;

        emit OfficialMintSettlementRegistered(
            refId,
            officialRequestId,
            stableAmount,
            officialAmount,
            pendingOfficialMintStable,
            registeredMintableBacking
        );
    }

    /// @notice Register an official mint rejection/refund and return the stable amount to pending deposits.
    /// @dev LABS must verify the official rejection and stablecoin refund before calling this function.
    function registerOfficialMintRejection(
        uint256 stableAmount,
        uint256 officialRequestId,
        bytes32 refId,
        bytes32 evidenceHash
    ) external nonReentrant whenNotPaused onlyRole(RECEIPT_MANAGER_ROLE) {
        require(stableAmount > 0, "stable_amount_zero");
        require(evidenceHash != bytes32(0), "evidence_zero");
        _consumeRef(refId);
        OfficialMintRequest storage request = officialMintRequests[officialRequestId];
        require(request.status == OfficialMintRequestStatus.Submitted, "official_request_not_submitted");
        require(request.stableAmount == stableAmount, "official_request_amount_mismatch");
        require(pendingOfficialMintStable >= stableAmount, "insufficient_pending_official_mint");

        pendingOfficialMintStable -= stableAmount;
        pendingStableDeposits += stableAmount;
        require(stablecoin.balanceOf(address(this)) >= classifiedStableBalance(), "stable_refund_not_received");
        request.terminalRefId = refId;
        request.evidenceHash = evidenceHash;
        request.status = OfficialMintRequestStatus.Rejected;

        emit OfficialMintRejected(
            refId,
            officialRequestId,
            evidenceHash,
            stableAmount,
            pendingStableDeposits,
            pendingOfficialMintStable
        );
    }

    /// @notice Register official token already received by this vault as eligible backing for future wrapped mint.
    function registerOfficialReceipt(
        uint256 amount,
        bytes32 refId,
        bytes32 evidenceHash,
        bytes32 sourceType
    ) external nonReentrant whenNotPaused onlyRole(RECEIPT_MANAGER_ROLE) {
        require(amount > 0, "amount_zero");
        require(evidenceHash != bytes32(0), "evidence_zero");
        require(sourceType != bytes32(0), "source_type_zero");
        _consumeRef(refId);
        registeredMintableBacking += amount;
        require(officialToken.balanceOf(address(this)) >= classifiedOfficialBacking(), "official_balance_deficit");
        emit OfficialReceiptRegistered(refId, sourceType, evidenceHash, amount, registeredMintableBacking);
    }

    /// @notice Mint wrapped token 1:1 by consuming previously registered official backing.
    function mintAgainstRegistered(
        address to,
        uint256 amount,
        bytes32 refId
    ) external nonReentrant whenNotPaused onlyRole(MINT_OPERATOR_ROLE) {
        require(to != address(0), "to_zero");
        require(amount > 0, "amount_zero");
        _consumeRef(refId);
        require(registeredMintableBacking >= amount, "insufficient_registered");

        registeredMintableBacking -= amount;
        accountedLocked += amount;
        require(officialToken.balanceOf(address(this)) >= classifiedOfficialBacking(), "official_balance_deficit");
        wrappedToken.mint(to, amount);
        _requireSupplyInvariant();

        emit WrappedMintedAgainstLock(refId, to, amount, accountedLocked);
    }

    /// @notice Burn wrapped token from a holder after approval, then queue official AI/AIX backing for official burn.
    function burnApprovedAndQueueOfficialBurn(
        address holder,
        uint256 amount,
        bytes32 refId
    ) external nonReentrant whenNotPaused onlyRole(REDEEM_OPERATOR_ROLE) {
        require(holder != address(0), "holder_zero");
        _burnAndRequestOfficialRedeem(holder, amount, refId);
    }

    /// @notice Burn wrapped token from a holder and atomically submit official requestBurn from this vault.
    function burnAndRequestOfficialRedeem(
        address holder,
        uint256 amount,
        bytes32 refId
    ) external nonReentrant whenNotPaused onlyRole(REDEEM_OPERATOR_ROLE) returns (uint256 officialBurnRequestId) {
        require(holder != address(0), "holder_zero");
        officialBurnRequestId = _burnAndRequestOfficialRedeem(holder, amount, refId);
    }

    /// @notice User-facing on-chain redeem request entrypoint.
    /// @dev Burns approved wrapped shares from msg.sender and submits the official redeem request from this vault.
    function requestRedeem(
        uint256 shares,
        address receiver,
        bytes32 requestId
    ) external nonReentrant whenNotPaused returns (uint256 officialBurnRequestId) {
        require(receiver != address(0), "receiver_zero");
        officialBurnRequestId = _burnAndRequestOfficialRedeem(msg.sender, shares, requestId);
        emit RedeemRequested(requestId, msg.sender, msg.sender, receiver, shares, officialBurnRequestId);
    }

    /// @notice Operator-facing redeem request entrypoint for REST/custody mediated orders.
    /// @dev Burns approved wrapped shares from owner and submits the official redeem request from this vault.
    function requestRedeemFor(
        address owner,
        uint256 shares,
        address receiver,
        bytes32 requestId
    ) external nonReentrant whenNotPaused onlyRole(REDEEM_OPERATOR_ROLE) returns (uint256 officialBurnRequestId) {
        require(owner != address(0), "owner_zero");
        require(receiver != address(0), "receiver_zero");
        officialBurnRequestId = _burnAndRequestOfficialRedeem(owner, shares, requestId);
        emit RedeemRequested(requestId, msg.sender, owner, receiver, shares, officialBurnRequestId);
    }

    /// @notice Confirm official AI/AIX has already been burned for specific redeem queues.
    /// @dev This does not prove Fireblocks or official-system facts. It binds the on-chain confirmation
    ///      to concrete queue refs and records the off-chain evidence hash used by LABS reconciliation.
    function confirmOfficialBurnBatch(
        bytes32 batchRefId,
        bytes32[] calldata queueRefIds,
        bytes32 evidenceHash
    ) external nonReentrant whenNotPaused onlyRole(OFFICIAL_BURN_CONFIRMER_ROLE) {
        require(queueRefIds.length > 0, "queue_empty");
        require(evidenceHash != bytes32(0), "evidence_zero");
        _consumeRef(batchRefId);
        uint256 amount = 0;
        uint256 payoutAmount = 0;
        for (uint256 index = 0; index < queueRefIds.length; index += 1) {
            bytes32 queueRefId = queueRefIds[index];
            RedeemQueue storage queue = redeemQueues[queueRefId];
            require(queue.status == RedeemQueueStatus.Queued, "redeem_queue_not_queued");
            (
                address officialUser,
                ,
                uint256 officialBurnAmount,
                uint256 officialPayoutAmount,
                uint8 officialStatus,
                ,
                ,
            ) = officialFundController.burnRequests(queue.officialBurnRequestId);
            require(officialUser == address(this), "official_burn_user_mismatch");
            require(officialBurnAmount == queue.amount, "official_burn_amount_mismatch");
            require(officialStatus == 1, "official_burn_not_settled");
            require(officialPayoutAmount > 0, "official_burn_payout_zero");
            queue.status = RedeemQueueStatus.Confirmed;
            queue.confirmBatchRefId = batchRefId;
            queue.payoutAmount = officialPayoutAmount;
            amount += queue.amount;
            payoutAmount += officialPayoutAmount;
        }
        require(pendingOfficialBurn >= amount, "insufficient_pending_burn");
        uint256 balanceAfterOfficialBurn = officialToken.balanceOf(address(this));
        pendingOfficialBurn -= amount;
        pendingRedeemStableProceeds += payoutAmount;
        require(balanceAfterOfficialBurn >= classifiedOfficialBacking(), "official_balance_deficit");
        require(stablecoin.balanceOf(address(this)) >= classifiedStableBalance(), "redeem_stable_not_received");

        emit OfficialBurnBatchConfirmed(
            batchRefId,
            evidenceHash,
            amount,
            payoutAmount,
            queueRefIds.length,
            pendingOfficialBurn,
            balanceAfterOfficialBurn,
            pendingRedeemStableProceeds
        );
    }

    /// @notice Release confirmed official redemption stablecoin proceeds to a LABS payout target.
    function releaseRedeemStableProceeds(
        address to,
        uint256 amount,
        bytes32 refId
    ) external nonReentrant whenNotPaused onlyRole(PAYMENT_OPERATOR_ROLE) {
        require(to != address(0), "to_zero");
        require(amount > 0, "amount_zero");
        _consumeRef(refId);
        require(pendingRedeemStableProceeds >= amount, "insufficient_redeem_stable");
        pendingRedeemStableProceeds -= amount;
        stablecoin.safeTransfer(to, amount);
        emit RedeemStableProceedsReleased(refId, to, amount, pendingRedeemStableProceeds);
    }

    /// @notice Classify a completed official dividend claim that has already transferred stablecoin to this vault.
    /// @dev The receipt manager must verify the official claim and the matching ERC20 Transfer before calling.
    function registerDividendStableReceipt(
        uint256 amount,
        bytes32 claimRef,
        bytes32 evidenceHash
    ) external nonReentrant whenNotPaused onlyRole(RECEIPT_MANAGER_ROLE) {
        require(amount > 0, "amount_zero");
        require(evidenceHash != bytes32(0), "evidence_zero");
        _consumeRef(claimRef);
        pendingDividendStableProceeds += amount;
        require(stablecoin.balanceOf(address(this)) >= classifiedStableBalance(), "dividend_stable_not_received");
        emit DividendStableReceiptRegistered(claimRef, evidenceHash, amount, pendingDividendStableProceeds);
    }

    /// @notice Release only classified official dividend stablecoin proceeds directly from this vault.
    function releaseDividendStableProceeds(
        address to,
        uint256 amount,
        bytes32 refId
    ) external nonReentrant whenNotPaused onlyRole(PAYMENT_OPERATOR_ROLE) {
        require(to != address(0), "to_zero");
        require(amount > 0, "amount_zero");
        _consumeRef(refId);
        require(pendingDividendStableProceeds >= amount, "insufficient_dividend_stable");
        pendingDividendStableProceeds -= amount;
        stablecoin.safeTransfer(to, amount);
        emit DividendStableProceedsReleased(refId, to, amount, pendingDividendStableProceeds);
    }

    /// @notice User-facing on-chain withdrawal request entrypoint.
    /// @dev Event-only. LABS must validate withdrawable balance and execute payout off-chain.
    function requestWithdrawal(
        bytes32 assetId,
        uint256 assets,
        address receiver,
        bytes32 sourceType,
        bytes32 sourceRef,
        bytes32 requestId
    ) external nonReentrant whenNotPaused {
        require(assetId != bytes32(0), "asset_zero");
        require(assets > 0, "amount_zero");
        require(receiver != address(0), "receiver_zero");
        require(sourceType != bytes32(0), "source_type_zero");
        require(sourceRef != bytes32(0), "source_ref_zero");
        _consumeRef(requestId);
        emit WithdrawalRequested(requestId, msg.sender, receiver, assetId, assets, sourceType, sourceRef);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Rescue tokens accidentally sent to this vault, except backing and wrapped product tokens.
    function rescueToken(address token, address to, uint256 amount) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(officialToken), "cannot_rescue_official");
        require(token != address(wrappedToken), "cannot_rescue_wrapped");
        require(token != address(0), "token_zero");
        require(to != address(0), "to_zero");
        require(amount > 0, "amount_zero");
        if (token == address(stablecoin)) {
            require(amount <= unregisteredStableBalance(), "cannot_rescue_pending_stable");
        }
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    function _burnAndRequestOfficialRedeem(
        address burnSource,
        uint256 amount,
        bytes32 refId
    ) private returns (uint256 officialBurnRequestId) {
        require(amount > 0, "amount_zero");
        _consumeRef(refId);
        require(accountedLocked >= amount, "insufficient_locked");
        require(
            officialToken.balanceOf(address(this)) >= classifiedOfficialBacking(),
            "official_balance_deficit"
        );

        wrappedToken.burnFrom(burnSource, amount);

        accountedLocked -= amount;
        officialBurnRequestId = officialFundController.requestBurn(amount);
        require(officialBurnRequestId != 0, "official_burn_request_zero");
        pendingOfficialBurn += amount;
        redeemQueues[refId] = RedeemQueue({
            holder: burnSource,
            amount: amount,
            officialBurnRequestId: officialBurnRequestId,
            payoutAmount: 0,
            confirmBatchRefId: bytes32(0),
            status: RedeemQueueStatus.Queued
        });
        _requireSupplyInvariant();
        require(
            officialToken.balanceOf(address(this)) >= classifiedOfficialBacking(),
            "official_balance_deficit"
        );

        emit WrappedBurnedAndOfficialBurnQueued(
            refId,
            burnSource,
            amount,
            officialBurnRequestId,
            accountedLocked,
            pendingOfficialBurn
        );
    }

    function _requireSupplyInvariant() private view {
        require(accountedLocked == wrappedToken.totalSupply(), "locked_supply_mismatch");
    }

    function _consumeRef(bytes32 refId) private {
        require(refId != bytes32(0), "ref_zero");
        require(!processedRefs[refId], "ref_used");
        processedRefs[refId] = true;
    }
}
