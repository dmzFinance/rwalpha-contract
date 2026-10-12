// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title InstitutionRestrictedFundController
/// @notice Fund shares transferable only between active members of the same institution.
/// @dev The Safe holds DEFAULT_ADMIN_ROLE. For this deployment, the same Fireblocks-controlled
///      address holds OPERATOR_ROLE, whitelist-manager authority and PAUSER_ROLE.
contract InstitutionRestrictedFundController is ERC20, AccessControl, ReentrancyGuard {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 public constant MAX_BATCH_SIZE = 100;

    enum MintStatus { Pending, Settled, Rejected }
    enum BurnStatus { Pending, Settled, Rejected }

    struct MintRequest {
        address user;
        // Retained for ABI compatibility; the current Mint flow does not collect or refund stablecoin.
        address collectionWallet;
        // User-declared subscription amount; actual payment is verified off-chain before settlement.
        uint256 stableAmount;
        uint256 mintedAmount;
        MintStatus status;
        uint64 createdAt;
        uint64 settledAt;
        bytes32 memo;
    }

    struct BurnRequest {
        address user;
        // Retained for ABI compatibility; redemption proceeds are paid off-chain.
        address payoutWallet;
        uint256 burnAmount;
        // Operator-declared off-chain payout amount, not an on-chain transfer receipt.
        uint256 payoutAmount;
        BurnStatus status;
        uint64 createdAt;
        uint64 settledAt;
        bytes32 memo;
    }

    struct DailyStatement {
        uint32 statementDate;
        uint256 nav;
        uint256 totalShares;
        uint256 netAssets;
        bytes32 fileHash;
        string uri;
        address publisher;
        uint64 publishedAt;
    }

    struct Institution {
        bool exists;
        bool active;
        bytes32 metadataHash;
    }

    IERC20 public immutable stablecoin;
    uint8 private immutable _tokenDecimals;
    uint256 private _minMintStableAmount;

    address public mintCollectionWallet;
    address public burnPayoutWallet;
    address public whitelistManager;
    address public pendingWhitelistManager;

    uint256 public nav;
    uint32 public latestStatementDate;

    bool public transfersPaused;
    bool public settlementsPaused;
    bool public whitelistOperationsPaused;

    uint256 public nextMintRequestId = 1;
    uint256 public nextBurnRequestId = 1;

    mapping(uint256 => MintRequest) public mintRequests;
    mapping(uint256 => BurnRequest) public burnRequests;
    mapping(uint32 => DailyStatement) private dailyStatements;

    mapping(bytes32 => Institution) public institutions;
    mapping(address => bytes32) public institutionOf;
    mapping(address => bool) public memberFrozen;
    mapping(address => uint256) public pendingMintCount;
    mapping(address => uint256) public pendingBurnCount;
    mapping(bytes32 => bool) public processedWhitelistOperations;

    bytes32[] private _institutionIds;
    mapping(bytes32 => address[]) private _institutionMembers;
    mapping(address => uint256) private _memberIndexPlusOne;

    event NavUpdated(uint256 oldNav, uint256 newNav);
    event MintRequested(uint256 indexed requestId, address indexed user, uint256 stableAmount);
    event MintSettled(
        uint256 indexed requestId,
        address indexed user,
        uint256 stableAmount,
        uint256 mintedAmount
    );
    event MintRejected(uint256 indexed requestId, address indexed user, uint256 requestedStableAmount);
    event BurnRequested(uint256 indexed requestId, address indexed user, uint256 burnAmount);
    event BurnSettled(
        uint256 indexed requestId,
        address indexed user,
        uint256 burnAmount,
        uint256 payoutAmount
    );
    event BurnRejected(uint256 indexed requestId, address indexed user, uint256 burnUnlockAmount);
    event DailyStatementPublished(
        uint32 indexed statementDate,
        uint256 nav,
        uint256 totalShares,
        uint256 netAssets,
        bytes32 fileHash,
        string uri,
        address indexed publisher
    );
    event MintCollectionWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event BurnPayoutWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event RequestWalletRecovered(
        bool indexed isMint,
        uint256 indexed requestId,
        address indexed oldWallet,
        address newWallet
    );
    event MinMintStableAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event WhitelistManagerProposed(address indexed currentManager, address indexed proposedManager);
    event WhitelistManagerUpdated(address indexed oldManager, address indexed newManager);
    event WhitelistManagerEmergencyUpdated(address indexed oldManager, address indexed newManager);
    event InstitutionCreated(bytes32 indexed institutionId, bytes32 metadataHash, bytes32 indexed operationId);
    event InstitutionStatusUpdated(bytes32 indexed institutionId, bool active, bytes32 indexed operationId);
    event InstitutionMetadataUpdated(
        bytes32 indexed institutionId,
        bytes32 oldMetadataHash,
        bytes32 newMetadataHash,
        bytes32 indexed operationId
    );
    event InstitutionMemberAdded(bytes32 indexed institutionId, address indexed account, bytes32 indexed operationId);
    event InstitutionMemberRemoved(bytes32 indexed institutionId, address indexed account, bytes32 indexed operationId);
    event MemberFrozenUpdated(address indexed account, bool frozen, bytes32 indexed operationId);
    event TransfersPaused(address indexed account);
    event TransfersUnpaused(address indexed account);
    event PauseStateUpdated(bytes32 indexed area, bool paused, address indexed account);

    error ZeroAddress();
    error InvalidAmount();
    error InvalidNav();
    error InvalidDate();
    error NonMonotonicDate(uint32 supplied, uint32 latest);
    error InvalidArrayLength();
    error InvalidRequestStatus();
    error InvalidHash();
    error RequestNotFound();
    error StatementAlreadyExists();
    error StatementNotFound();
    error InvalidTokenDecimals();
    error DelegatedTransferDisabled();
    error WhitelistManagerOnly(address caller);
    error InvalidInstitutionId();
    error InstitutionAlreadyExists(bytes32 institutionId);
    error InstitutionNotFound(bytes32 institutionId);
    error InstitutionInactive(bytes32 institutionId);
    error InstitutionMismatch(address from, address to);
    error MemberAlreadyAssigned(address account, bytes32 institutionId);
    error MemberNotAssigned(address account);
    error MemberIsFrozen(address account);
    error MemberMustBeFrozen(address account);
    error AccountNotClear(address account, uint256 balance, uint256 pendingMints, uint256 pendingBurns);
    error TransfersArePaused();
    error SettlementsArePaused();
    error WhitelistOperationsArePaused();
    error NoStateChange();
    error InvalidOperationId();
    error OperationAlreadyProcessed(bytes32 operationId);
    error BatchSizeExceeded(uint256 supplied, uint256 maximum);
    error NotPendingWhitelistManager(address caller);
    error InvalidOperationalWallet(address wallet);
    error OperationalWalletCannotBeMember(address wallet);

    modifier onlyWhitelistManager() {
        if (msg.sender != whitelistManager) revert WhitelistManagerOnly(msg.sender);
        _;
    }

    modifier whenWhitelistOperationsActive() {
        if (whitelistOperationsPaused) revert WhitelistOperationsArePaused();
        _;
    }

    modifier whenSettlementsActive() {
        if (settlementsPaused) revert SettlementsArePaused();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address admin_,
        address operator_,
        address whitelistManager_,
        address pauser_,
        address stablecoin_,
        address mintCollectionWallet_,
        address burnPayoutWallet_,
        uint256 initialNav_
    ) ERC20(name_, symbol_) {
        if (
            admin_ == address(0) ||
            operator_ == address(0) ||
            whitelistManager_ == address(0) ||
            pauser_ == address(0) ||
            stablecoin_ == address(0)
        ) revert ZeroAddress();
        if (initialNav_ == 0) revert InvalidNav();

        stablecoin = IERC20(stablecoin_);
        _tokenDecimals = IERC20Metadata(stablecoin_).decimals();
        if (_tokenDecimals > 75) revert InvalidTokenDecimals();

        _validateOperationalWallet(mintCollectionWallet_);
        _validateOperationalWallet(burnPayoutWallet_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(OPERATOR_ROLE, operator_);
        _grantRole(PAUSER_ROLE, pauser_);

        whitelistManager = whitelistManager_;
        _minMintStableAmount = 100 * (10 ** _tokenDecimals);
        mintCollectionWallet = mintCollectionWallet_;
        burnPayoutWallet = burnPayoutWallet_;
        nav = initialNav_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function setNav(uint256 newNav) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setNav(newNav);
    }

    function setMinMintStableAmount(uint256 newMinAmount) external onlyRole(OPERATOR_ROLE) {
        uint256 minimumAllowed = 100 * (10 ** _tokenDecimals);
        if (newMinAmount < minimumAllowed) revert InvalidAmount();
        uint256 oldAmount = _minMintStableAmount;
        _minMintStableAmount = newMinAmount;
        emit MinMintStableAmountUpdated(oldAmount, newMinAmount);
    }

    function proposeWhitelistManager(address newManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newManager == address(0)) revert ZeroAddress();
        if (newManager == whitelistManager || newManager == pendingWhitelistManager) revert NoStateChange();
        pendingWhitelistManager = newManager;
        emit WhitelistManagerProposed(whitelistManager, newManager);
    }

    function acceptWhitelistManager() external {
        if (msg.sender != pendingWhitelistManager) revert NotPendingWhitelistManager(msg.sender);
        address oldManager = whitelistManager;
        whitelistManager = msg.sender;
        pendingWhitelistManager = address(0);
        emit WhitelistManagerUpdated(oldManager, msg.sender);
    }

    /// @notice Safe-only incident response path; bypasses the normal two-step handover.
    function emergencySetWhitelistManager(address newManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newManager == address(0)) revert ZeroAddress();
        if (newManager == whitelistManager) revert NoStateChange();
        address oldManager = whitelistManager;
        whitelistManager = newManager;
        pendingWhitelistManager = address(0);
        emit WhitelistManagerUpdated(oldManager, newManager);
        emit WhitelistManagerEmergencyUpdated(oldManager, newManager);
    }

    function createInstitution(bytes32 institutionId, bytes32 metadataHash, bytes32 operationId)
        external
        onlyWhitelistManager
        whenWhitelistOperationsActive
    {
        _consumeWhitelistOperation(operationId);
        if (institutionId == bytes32(0)) revert InvalidInstitutionId();
        if (institutions[institutionId].exists) revert InstitutionAlreadyExists(institutionId);
        institutions[institutionId] = Institution(true, true, metadataHash);
        _institutionIds.push(institutionId);
        emit InstitutionCreated(institutionId, metadataHash, operationId);
    }

    function setInstitutionActive(bytes32 institutionId, bool active, bytes32 operationId)
        external
        onlyWhitelistManager
        whenWhitelistOperationsActive
    {
        _consumeWhitelistOperation(operationId);
        Institution storage institution = _getInstitution(institutionId);
        if (institution.active == active) revert NoStateChange();
        institution.active = active;
        emit InstitutionStatusUpdated(institutionId, active, operationId);
    }

    function setInstitutionMetadataHash(bytes32 institutionId, bytes32 newMetadataHash, bytes32 operationId)
        external
        onlyWhitelistManager
        whenWhitelistOperationsActive
    {
        _consumeWhitelistOperation(operationId);
        Institution storage institution = _getInstitution(institutionId);
        if (institution.metadataHash == newMetadataHash) revert NoStateChange();
        bytes32 oldMetadataHash = institution.metadataHash;
        institution.metadataHash = newMetadataHash;
        emit InstitutionMetadataUpdated(institutionId, oldMetadataHash, newMetadataHash, operationId);
    }

    function addMember(bytes32 institutionId, address account, bytes32 operationId)
        external
        onlyWhitelistManager
        whenWhitelistOperationsActive
    {
        _consumeWhitelistOperation(operationId);
        _addMember(institutionId, account, operationId);
    }

    function batchAddMembers(bytes32 institutionId, address[] calldata accounts, bytes32 operationId)
        external
        onlyWhitelistManager
        whenWhitelistOperationsActive
    {
        _validateBatchLength(accounts.length);
        _consumeWhitelistOperation(operationId);
        for (uint256 i = 0; i < accounts.length; ++i) _addMember(institutionId, accounts[i], operationId);
    }

    function removeMember(address account, bytes32 operationId)
        external
        onlyWhitelistManager
        whenWhitelistOperationsActive
    {
        _consumeWhitelistOperation(operationId);
        _removeMember(account, operationId);
    }

    function batchRemoveMembers(address[] calldata accounts, bytes32 operationId)
        external
        onlyWhitelistManager
        whenWhitelistOperationsActive
    {
        _validateBatchLength(accounts.length);
        _consumeWhitelistOperation(operationId);
        for (uint256 i = 0; i < accounts.length; ++i) _removeMember(accounts[i], operationId);
    }

    function setMemberFrozen(address account, bool frozen, bytes32 operationId)
        external
        onlyWhitelistManager
        whenWhitelistOperationsActive
    {
        _consumeWhitelistOperation(operationId);
        _requireAssignedMember(account);
        if (memberFrozen[account] == frozen) revert NoStateChange();
        memberFrozen[account] = frozen;
        emit MemberFrozenUpdated(account, frozen, operationId);
    }

    function pauseTransfers() external onlyRole(PAUSER_ROLE) {
        if (transfersPaused) revert NoStateChange();
        transfersPaused = true;
        emit TransfersPaused(msg.sender);
        emit PauseStateUpdated("TRANSFERS", true, msg.sender);
    }

    /// @notice Kept for compatibility; only Safe governance may resume transfers.
    function unpauseTransfers() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!transfersPaused) revert NoStateChange();
        transfersPaused = false;
        emit TransfersUnpaused(msg.sender);
        emit PauseStateUpdated("TRANSFERS", false, msg.sender);
    }

    function pauseSettlements() external onlyRole(PAUSER_ROLE) {
        if (settlementsPaused) revert NoStateChange();
        settlementsPaused = true;
        emit PauseStateUpdated("SETTLEMENTS", true, msg.sender);
    }

    function pauseWhitelistOperations() external onlyRole(PAUSER_ROLE) {
        if (whitelistOperationsPaused) revert NoStateChange();
        whitelistOperationsPaused = true;
        emit PauseStateUpdated("WHITELIST", true, msg.sender);
    }

    function pauseAll() external onlyRole(PAUSER_ROLE) {
        transfersPaused = true;
        settlementsPaused = true;
        whitelistOperationsPaused = true;
        emit TransfersPaused(msg.sender);
        emit PauseStateUpdated("ALL", true, msg.sender);
    }

    /// @notice Only Safe governance may resume operations after an incident.
    function unpauseAll() external onlyRole(DEFAULT_ADMIN_ROLE) {
        transfersPaused = false;
        settlementsPaused = false;
        whitelistOperationsPaused = false;
        emit TransfersUnpaused(msg.sender);
        emit PauseStateUpdated("ALL", false, msg.sender);
    }

    function setPauseState(bool transferPause, bool settlementPause, bool whitelistPause)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        bool transferStateChanged = transfersPaused != transferPause;
        transfersPaused = transferPause;
        settlementsPaused = settlementPause;
        whitelistOperationsPaused = whitelistPause;
        if (transferStateChanged) {
            if (transferPause) emit TransfersPaused(msg.sender);
            else emit TransfersUnpaused(msg.sender);
        }
        emit PauseStateUpdated("CUSTOM", transferPause || settlementPause || whitelistPause, msg.sender);
    }

    function isActiveMember(address account) public view returns (bool) {
        bytes32 institutionId = institutionOf[account];
        return institutionId != bytes32(0) && institutions[institutionId].exists &&
            institutions[institutionId].active && !memberFrozen[account];
    }

    function canTransfer(address from, address to) public view returns (bool) {
        if (transfersPaused || memberFrozen[from] || memberFrozen[to]) return false;
        bytes32 fromInstitution = institutionOf[from];
        if (fromInstitution == bytes32(0) || fromInstitution != institutionOf[to]) return false;
        Institution storage institution = institutions[fromInstitution];
        return institution.exists && institution.active;
    }

    function getInstitutionIds() external view returns (bytes32[] memory) {
        return _institutionIds;
    }

    function getInstitutionMembers(bytes32 institutionId) external view returns (address[] memory) {
        _getInstitution(institutionId);
        return _institutionMembers[institutionId];
    }

    function getInstitutionMemberDetails(bytes32 institutionId)
        external
        view
        returns (address[] memory members, bool[] memory frozenStates)
    {
        _getInstitution(institutionId);
        members = _institutionMembers[institutionId];
        frozenStates = new bool[](members.length);
        for (uint256 i = 0; i < members.length; ++i) {
            frozenStates[i] = memberFrozen[members[i]];
        }
    }

    /// @notice Records a whitelisted member's subscription request without moving stablecoin.
    /// @dev The Operator must verify payment off-chain before settleMint or batchSettleMint.
    function requestMint(uint256 stableAmount) external nonReentrant returns (uint256 requestId) {
        _requireActiveUnfrozenMember(msg.sender);
        if (stableAmount < _minMintStableAmount) revert InvalidAmount();

        requestId = nextMintRequestId++;
        mintRequests[requestId] = MintRequest({
            user: msg.sender,
            collectionWallet: mintCollectionWallet,
            stableAmount: stableAmount,
            mintedAmount: 0,
            status: MintStatus.Pending,
            createdAt: uint64(block.timestamp),
            settledAt: 0,
            memo: bytes32(0)
        });
        pendingMintCount[msg.sender] += 1;
        emit MintRequested(requestId, msg.sender, stableAmount);
    }

    /// @notice Burn requests remain available while frozen or paused so members can exit.
    function requestBurn(uint256 burnAmount) external nonReentrant returns (uint256 requestId) {
        _requireAssignedMember(msg.sender);
        if (burnAmount == 0) revert InvalidAmount();
        _transferToVault(msg.sender, burnAmount);

        requestId = nextBurnRequestId++;
        burnRequests[requestId] = BurnRequest({
            user: msg.sender,
            payoutWallet: burnPayoutWallet,
            burnAmount: burnAmount,
            payoutAmount: 0,
            status: BurnStatus.Pending,
            createdAt: uint64(block.timestamp),
            settledAt: 0,
            memo: bytes32(0)
        });
        pendingBurnCount[msg.sender] += 1;
        emit BurnRequested(requestId, msg.sender, burnAmount);
    }

    function settleMint(uint256 requestId, uint256 mintedAmount, bytes32 memo)
        external
        onlyRole(OPERATOR_ROLE)
        whenSettlementsActive
        nonReentrant
    {
        _settleMint(requestId, mintedAmount, memo);
    }

    function rejectMint(uint256 requestId, bytes32 memo)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        _rejectMint(requestId, memo);
    }

    function settleBurn(uint256 requestId, uint256 payoutAmount, bytes32 memo)
        external
        onlyRole(OPERATOR_ROLE)
        whenSettlementsActive
        nonReentrant
    {
        _settleBurn(requestId, payoutAmount, memo);
    }

    function rejectBurn(uint256 requestId, bytes32 memo)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        _rejectBurn(requestId, memo);
    }

    function batchSettleMint(uint256[] calldata requestIds, uint256[] calldata amounts, bytes32[] calldata memos)
        external
        onlyRole(OPERATOR_ROLE)
        whenSettlementsActive
        nonReentrant
    {
        uint256 length = requestIds.length;
        _validateBatchLength(length);
        if (length != amounts.length || length != memos.length) revert InvalidArrayLength();
        for (uint256 i = 0; i < length; ++i) _settleMint(requestIds[i], amounts[i], memos[i]);
    }

    function batchRejectMint(uint256[] calldata requestIds, bytes32[] calldata memos)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        uint256 length = requestIds.length;
        _validateBatchLength(length);
        if (length != memos.length) revert InvalidArrayLength();
        for (uint256 i = 0; i < length; ++i) _rejectMint(requestIds[i], memos[i]);
    }

    function batchSettleBurn(uint256[] calldata requestIds, uint256[] calldata amounts, bytes32[] calldata memos)
        external
        onlyRole(OPERATOR_ROLE)
        whenSettlementsActive
        nonReentrant
    {
        uint256 length = requestIds.length;
        _validateBatchLength(length);
        if (length != amounts.length || length != memos.length) revert InvalidArrayLength();
        for (uint256 i = 0; i < length; ++i) _settleBurn(requestIds[i], amounts[i], memos[i]);
    }

    function batchRejectBurn(uint256[] calldata requestIds, bytes32[] calldata memos)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        uint256 length = requestIds.length;
        _validateBatchLength(length);
        if (length != memos.length) revert InvalidArrayLength();
        for (uint256 i = 0; i < length; ++i) _rejectBurn(requestIds[i], memos[i]);
    }

    /// @notice Safe may keep recovery/rejection available while Operator settlement is paused.
    function emergencyRejectMint(uint256 requestId, bytes32 memo)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        _rejectMint(requestId, memo);
    }

    function emergencyRejectBurn(uint256 requestId, bytes32 memo)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        _rejectBurn(requestId, memo);
    }

    function setMintCollectionWallet(address newWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateOperationalWallet(newWallet);
        address oldWallet = mintCollectionWallet;
        if (oldWallet == newWallet) revert NoStateChange();
        mintCollectionWallet = newWallet;
        emit MintCollectionWalletUpdated(oldWallet, newWallet);
    }

    function setBurnPayoutWallet(address newWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateOperationalWallet(newWallet);
        address oldWallet = burnPayoutWallet;
        if (oldWallet == newWallet) revert NoStateChange();
        burnPayoutWallet = newWallet;
        emit BurnPayoutWalletUpdated(oldWallet, newWallet);
    }

    function recoverMintRequestWallet(uint256 requestId, address newWallet)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _validateOperationalWallet(newWallet);
        MintRequest storage r = mintRequests[requestId];
        if (r.user == address(0)) revert RequestNotFound();
        if (r.status != MintStatus.Pending) revert InvalidRequestStatus();
        address oldWallet = r.collectionWallet;
        if (oldWallet == newWallet) revert NoStateChange();
        r.collectionWallet = newWallet;
        emit RequestWalletRecovered(true, requestId, oldWallet, newWallet);
    }

    function recoverBurnRequestWallet(uint256 requestId, address newWallet)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _validateOperationalWallet(newWallet);
        BurnRequest storage r = burnRequests[requestId];
        if (r.user == address(0)) revert RequestNotFound();
        if (r.status != BurnStatus.Pending) revert InvalidRequestStatus();
        address oldWallet = r.payoutWallet;
        if (oldWallet == newWallet) revert NoStateChange();
        r.payoutWallet = newWallet;
        emit RequestWalletRecovered(false, requestId, oldWallet, newWallet);
    }

    function publishDailyStatement(
        uint32 statementDate,
        uint256 statementNav,
        uint256 totalShares,
        uint256 netAssets,
        bytes32 fileHash,
        string calldata uri
    ) external onlyRole(OPERATOR_ROLE) {
        _publishDailyStatement(statementDate, statementNav, totalShares, netAssets, fileHash, uri);
    }

    function publishDailyStatementAndSetNav(
        uint32 statementDate,
        uint256 statementNav,
        uint256 totalShares,
        uint256 netAssets,
        bytes32 fileHash,
        string calldata uri
    ) external onlyRole(OPERATOR_ROLE) {
        _setNav(statementNav);
        _publishDailyStatement(statementDate, statementNav, totalShares, netAssets, fileHash, uri);
    }

    function getDailyStatement(uint32 statementDate) external view returns (DailyStatement memory) {
        DailyStatement memory statement = dailyStatements[statementDate];
        if (statement.publishedAt == 0) revert StatementNotFound();
        return statement;
    }

    function hasDailyStatement(uint32 statementDate) external view returns (bool) {
        return dailyStatements[statementDate].publishedAt != 0;
    }

    function getStableAddress() external view returns (address) { return address(stablecoin); }
    function getMinMintStableAmount() external view returns (uint256) { return _minMintStableAmount; }

    function approve(address, uint256) public pure override returns (bool) {
        revert DelegatedTransferDisabled();
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert DelegatedTransferDisabled();
    }

    function _publishDailyStatement(
        uint32 statementDate,
        uint256 statementNav,
        uint256 totalShares,
        uint256 netAssets,
        bytes32 fileHash,
        string calldata uri
    ) internal {
        if (statementDate == 0) revert InvalidDate();
        if (statementDate <= latestStatementDate) revert NonMonotonicDate(statementDate, latestStatementDate);
        if (statementNav == 0 || totalShares == 0 || netAssets == 0) revert InvalidAmount();
        if (fileHash == bytes32(0)) revert InvalidHash();
        if (dailyStatements[statementDate].publishedAt != 0) revert StatementAlreadyExists();
        dailyStatements[statementDate] = DailyStatement(
            statementDate, statementNav, totalShares, netAssets, fileHash, uri, msg.sender, uint64(block.timestamp)
        );
        latestStatementDate = statementDate;
        emit DailyStatementPublished(statementDate, statementNav, totalShares, netAssets, fileHash, uri, msg.sender);
    }

    function _setNav(uint256 newNav) internal {
        if (newNav == 0) revert InvalidNav();
        uint256 oldNav = nav;
        nav = newNav;
        emit NavUpdated(oldNav, newNav);
    }

    function _settleMint(uint256 requestId, uint256 mintedAmount, bytes32 memo) internal {
        MintRequest storage r = mintRequests[requestId];
        if (r.user == address(0)) revert RequestNotFound();
        if (r.status != MintStatus.Pending) revert InvalidRequestStatus();
        if (mintedAmount == 0) revert InvalidAmount();
        _requireActiveUnfrozenMember(r.user);

        r.status = MintStatus.Settled;
        r.mintedAmount = mintedAmount;
        r.settledAt = uint64(block.timestamp);
        r.memo = memo;
        pendingMintCount[r.user] -= 1;
        _mint(r.user, mintedAmount);
        emit MintSettled(requestId, r.user, r.stableAmount, mintedAmount);
    }

    function _rejectMint(uint256 requestId, bytes32 memo) internal {
        MintRequest storage r = mintRequests[requestId];
        if (r.user == address(0)) revert RequestNotFound();
        if (r.status != MintStatus.Pending) revert InvalidRequestStatus();
        r.status = MintStatus.Rejected;
        r.settledAt = uint64(block.timestamp);
        r.memo = memo;
        pendingMintCount[r.user] -= 1;
        emit MintRejected(requestId, r.user, r.stableAmount);
    }

    /// @dev Burns escrowed fund shares and records the off-chain redemption amount.
    ///      The Operator must verify payment off-chain before settlement.
    function _settleBurn(uint256 requestId, uint256 payoutAmount, bytes32 memo) internal {
        BurnRequest storage r = burnRequests[requestId];
        if (r.user == address(0)) revert RequestNotFound();
        if (r.status != BurnStatus.Pending) revert InvalidRequestStatus();
        if (payoutAmount == 0) revert InvalidAmount();

        r.status = BurnStatus.Settled;
        r.payoutAmount = payoutAmount;
        r.settledAt = uint64(block.timestamp);
        r.memo = memo;
        pendingBurnCount[r.user] -= 1;
        _burn(address(this), r.burnAmount);
        emit BurnSettled(requestId, r.user, r.burnAmount, payoutAmount);
    }

    function _rejectBurn(uint256 requestId, bytes32 memo) internal {
        BurnRequest storage r = burnRequests[requestId];
        if (r.user == address(0)) revert RequestNotFound();
        if (r.status != BurnStatus.Pending) revert InvalidRequestStatus();
        r.status = BurnStatus.Rejected;
        r.settledAt = uint64(block.timestamp);
        r.memo = memo;
        pendingBurnCount[r.user] -= 1;
        _transferFromVault(r.user, r.burnAmount);
        emit BurnRejected(requestId, r.user, r.burnAmount);
    }

    function _addMember(bytes32 institutionId, address account, bytes32 operationId) internal {
        if (account == address(0) || account == address(this)) revert ZeroAddress();
        if (account == mintCollectionWallet || account == burnPayoutWallet) {
            revert OperationalWalletCannotBeMember(account);
        }
        Institution storage institution = _getInstitution(institutionId);
        if (!institution.active) revert InstitutionInactive(institutionId);
        bytes32 currentInstitution = institutionOf[account];
        if (currentInstitution != bytes32(0)) revert MemberAlreadyAssigned(account, currentInstitution);
        institutionOf[account] = institutionId;
        _institutionMembers[institutionId].push(account);
        _memberIndexPlusOne[account] = _institutionMembers[institutionId].length;
        emit InstitutionMemberAdded(institutionId, account, operationId);
    }

    function _removeMember(address account, bytes32 operationId) internal {
        bytes32 institutionId = _requireAssignedMember(account);
        if (!memberFrozen[account]) revert MemberMustBeFrozen(account);
        uint256 accountBalance = balanceOf(account);
        uint256 pendingMints = pendingMintCount[account];
        uint256 pendingBurns = pendingBurnCount[account];
        if (accountBalance != 0 || pendingMints != 0 || pendingBurns != 0) {
            revert AccountNotClear(account, accountBalance, pendingMints, pendingBurns);
        }

        address[] storage members = _institutionMembers[institutionId];
        uint256 memberIndex = _memberIndexPlusOne[account] - 1;
        uint256 lastIndex = members.length - 1;
        if (memberIndex != lastIndex) {
            address lastMember = members[lastIndex];
            members[memberIndex] = lastMember;
            _memberIndexPlusOne[lastMember] = memberIndex + 1;
        }
        members.pop();

        delete _memberIndexPlusOne[account];
        delete institutionOf[account];
        delete memberFrozen[account];
        emit InstitutionMemberRemoved(institutionId, account, operationId);
    }

    function _getInstitution(bytes32 institutionId) internal view returns (Institution storage institution) {
        if (institutionId == bytes32(0)) revert InvalidInstitutionId();
        institution = institutions[institutionId];
        if (!institution.exists) revert InstitutionNotFound(institutionId);
    }

    function _requireAssignedMember(address account) internal view returns (bytes32 institutionId) {
        institutionId = institutionOf[account];
        if (institutionId == bytes32(0)) revert MemberNotAssigned(account);
    }

    function _requireActiveUnfrozenMember(address account) internal view {
        bytes32 institutionId = _requireAssignedMember(account);
        Institution storage institution = institutions[institutionId];
        if (!institution.exists || !institution.active) revert InstitutionInactive(institutionId);
        if (memberFrozen[account]) revert MemberIsFrozen(account);
    }

    function _requirePeerTransferAllowed(address from, address to) internal view {
        if (transfersPaused) revert TransfersArePaused();
        bytes32 fromInstitution = _requireAssignedMember(from);
        bytes32 toInstitution = _requireAssignedMember(to);
        if (fromInstitution != toInstitution) revert InstitutionMismatch(from, to);
        Institution storage institution = institutions[fromInstitution];
        if (!institution.exists || !institution.active) revert InstitutionInactive(fromInstitution);
        if (memberFrozen[from]) revert MemberIsFrozen(from);
        if (memberFrozen[to]) revert MemberIsFrozen(to);
    }

    function _consumeWhitelistOperation(bytes32 operationId) internal {
        if (operationId == bytes32(0)) revert InvalidOperationId();
        if (processedWhitelistOperations[operationId]) revert OperationAlreadyProcessed(operationId);
        processedWhitelistOperations[operationId] = true;
    }

    function _validateBatchLength(uint256 length) internal pure {
        if (length == 0) revert InvalidArrayLength();
        if (length > MAX_BATCH_SIZE) revert BatchSizeExceeded(length, MAX_BATCH_SIZE);
    }

    function _validateOperationalWallet(address wallet) internal view {
        if (wallet == address(0) || wallet == address(this) || wallet == address(stablecoin)) {
            revert InvalidOperationalWallet(wallet);
        }
        if (institutionOf[wallet] != bytes32(0)) revert OperationalWalletCannotBeMember(wallet);
    }

    function _transferToVault(address from, uint256 amount) internal {
        super._update(from, address(this), amount);
    }

    function _transferFromVault(address to, uint256 amount) internal {
        super._update(address(this), to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        bool isMint = from == address(0);
        bool isBurn = to == address(0);
        if (isMint) _requireActiveUnfrozenMember(to);
        else if (!isBurn) _requirePeerTransferAllowed(from, to);
        super._update(from, to, value);
    }
}
