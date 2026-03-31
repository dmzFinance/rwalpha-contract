// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract FundController is ERC20, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    enum MintStatus {
        Pending,
        Settled,
        Rejected
    }

    enum BurnStatus {
        Pending,
        Settled,
        Rejected
    }

    struct MintRequest {
        address user;
        address collectionWallet;
        uint256 stableAmount;
        uint256 mintedAmount;
        MintStatus status;
        uint64 createdAt;
        uint64 settledAt;
        bytes32 memo;
    }

    struct BurnRequest {
        address user;
        address payoutWallet;
        uint256 burnAmount;
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

    IERC20 public immutable stablecoin;

    address public mintCollectionWallet;
    address public burnPayoutWallet;
    uint256 public nav;

    uint256 public nextMintRequestId = 1;
    uint256 public nextBurnRequestId = 1;

    mapping(uint256 => MintRequest) public mintRequests;
    mapping(uint256 => BurnRequest) public burnRequests;
    mapping(uint32 => DailyStatement) private dailyStatements;

    event NavUpdated(uint256 oldNav, uint256 newNav);
    event MintRequested(
        uint256 indexed requestId,
        address indexed user,
        uint256 stableAmount
    );
    event MintSettled(
        uint256 indexed requestId,
        address indexed user,
        uint256 stableAmount,
        uint256 mintedAmount
    );
    event MintRejected(
        uint256 indexed requestId,
        address indexed user,
        uint256 stableRefundAmount
    );
    event BurnRequested(
        uint256 indexed requestId,
        address indexed user,
        uint256 burnAmount
    );
    event BurnSettled(
        uint256 indexed requestId,
        address indexed user,
        uint256 burnAmount,
        uint256 payoutAmount
    );
    event BurnRejected(
        uint256 indexed requestId,
        address indexed user,
        uint256 burnUnlockAmount
    );
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

    error ZeroAddress();
    error InvalidAmount();
    error InvalidNav();
    error InvalidDate();
    error InvalidArrayLength();
    error InvalidRequestStatus();
    error InvalidHash();
    error RequestNotFound();
    error StatementAlreadyExists();
    error StatementNotFound();

    constructor(
        string memory name_,
        string memory symbol_,
        address admin_,
        address operator_,
        address stablecoin_,
        address mintCollectionWallet_,
        address burnPayoutWallet_,
        uint256 initialNav_
    ) ERC20(name_, symbol_) {
        if (
            admin_ == address(0) ||
            operator_ == address(0) ||
            stablecoin_ == address(0) ||
            mintCollectionWallet_ == address(0) ||
            burnPayoutWallet_ == address(0)
        ) revert ZeroAddress();
        if (initialNav_ == 0) revert InvalidNav();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(OPERATOR_ROLE, operator_);

        stablecoin = IERC20(stablecoin_);
        mintCollectionWallet = mintCollectionWallet_;
        burnPayoutWallet = burnPayoutWallet_;
        nav = initialNav_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setNav(uint256 newNav) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setNav(newNav);
    }

    function requestMint(uint256 stableAmount)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        if (stableAmount == 0) revert InvalidAmount();

        stablecoin.safeTransferFrom(msg.sender, mintCollectionWallet, stableAmount);

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

        emit MintRequested(requestId, msg.sender, stableAmount);
    }

    function requestBurn(uint256 burnAmount)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        if (burnAmount == 0) revert InvalidAmount();

        _transfer(msg.sender, address(this), burnAmount);

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

        emit BurnRequested(requestId, msg.sender, burnAmount);
    }

    function settleMint(
        uint256 requestId,
        uint256 mintedAmount,
        bytes32 memo
    ) external onlyRole(OPERATOR_ROLE) nonReentrant {
        _settleMint(requestId, mintedAmount, memo);
    }

    function rejectMint(
        uint256 requestId,
        bytes32 memo
    ) external onlyRole(OPERATOR_ROLE) nonReentrant {
        _rejectMint(requestId, memo);
    }

    function settleBurn(
        uint256 requestId,
        uint256 payoutAmount,
        bytes32 memo
    ) external onlyRole(OPERATOR_ROLE) nonReentrant {
        _settleBurn(requestId, payoutAmount, memo);
    }

    function rejectBurn(
        uint256 requestId,
        bytes32 memo
    ) external onlyRole(OPERATOR_ROLE) nonReentrant {
        _rejectBurn(requestId, memo);
    }

    function batchSettleMint(
        uint256[] calldata requestIds,
        uint256[] calldata mintedAmounts,
        bytes32[] calldata memos
    ) external onlyRole(OPERATOR_ROLE) nonReentrant {
        uint256 length = requestIds.length;
        if (length != mintedAmounts.length || length != memos.length) revert InvalidArrayLength();

        for (uint256 i = 0; i < length; ++i) {
            _settleMint(requestIds[i], mintedAmounts[i], memos[i]);
        }
    }

    function batchRejectMint(
        uint256[] calldata requestIds,
        bytes32[] calldata memos
    ) external onlyRole(OPERATOR_ROLE) nonReentrant {
        uint256 length = requestIds.length;
        if (length != memos.length) revert InvalidArrayLength();

        for (uint256 i = 0; i < length; ++i) {
            _rejectMint(requestIds[i], memos[i]);
        }
    }

    function batchSettleBurn(
        uint256[] calldata requestIds,
        uint256[] calldata payoutAmounts,
        bytes32[] calldata memos
    ) external onlyRole(OPERATOR_ROLE) nonReentrant {
        uint256 length = requestIds.length;
        if (length != payoutAmounts.length || length != memos.length) revert InvalidArrayLength();

        for (uint256 i = 0; i < length; ++i) {
            _settleBurn(requestIds[i], payoutAmounts[i], memos[i]);
        }
    }

    function batchRejectBurn(
        uint256[] calldata requestIds,
        bytes32[] calldata memos
    ) external onlyRole(OPERATOR_ROLE) nonReentrant {
        uint256 length = requestIds.length;
        if (length != memos.length) revert InvalidArrayLength();

        for (uint256 i = 0; i < length; ++i) {
            _rejectBurn(requestIds[i], memos[i]);
        }
    }

    function setMintCollectionWallet(address newMintCollectionWallet)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newMintCollectionWallet == address(0)) revert ZeroAddress();

        address old = mintCollectionWallet;
        mintCollectionWallet = newMintCollectionWallet;

        emit MintCollectionWalletUpdated(old, newMintCollectionWallet);
    }

    function setBurnPayoutWallet(address newBurnPayoutWallet)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newBurnPayoutWallet == address(0)) revert ZeroAddress();

        address old = burnPayoutWallet;
        burnPayoutWallet = newBurnPayoutWallet;

        emit BurnPayoutWalletUpdated(old, newBurnPayoutWallet);
    }

    function getStableAddress() external view returns (address) {
        return address(stablecoin);
    }

    function publishDailyStatement(
        uint32 statementDate,
        uint256 statementNav,
        uint256 totalShares,
        uint256 netAssets,
        bytes32 fileHash,
        string calldata uri
    ) external onlyRole(OPERATOR_ROLE) {
        _publishDailyStatement(
            statementDate,
            statementNav,
            totalShares,
            netAssets,
            fileHash,
            uri
        );
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
        _publishDailyStatement(
            statementDate,
            statementNav,
            totalShares,
            netAssets,
            fileHash,
            uri
        );
    }

    function getDailyStatement(uint32 statementDate)
        external
        view
        returns (DailyStatement memory)
    {
        DailyStatement memory statement = dailyStatements[statementDate];
        if (statement.publishedAt == 0) revert StatementNotFound();
        return statement;
    }

    function hasDailyStatement(uint32 statementDate) external view returns (bool) {
        return dailyStatements[statementDate].publishedAt != 0;
    }

    function _setNav(uint256 newNav) internal {
        if (newNav == 0) revert InvalidNav();

        uint256 oldNav = nav;
        nav = newNav;

        emit NavUpdated(oldNav, newNav);
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
        if (statementNav == 0 || totalShares == 0 || netAssets == 0) revert InvalidAmount();
        if (fileHash == bytes32(0)) revert InvalidHash();
        if (dailyStatements[statementDate].publishedAt != 0) revert StatementAlreadyExists();

        dailyStatements[statementDate] = DailyStatement({
            statementDate: statementDate,
            nav: statementNav,
            totalShares: totalShares,
            netAssets: netAssets,
            fileHash: fileHash,
            uri: uri,
            publisher: msg.sender,
            publishedAt: uint64(block.timestamp)
        });

        emit DailyStatementPublished(
            statementDate,
            statementNav,
            totalShares,
            netAssets,
            fileHash,
            uri,
            msg.sender
        );
    }

    function _settleMint(uint256 requestId, uint256 mintedAmount, bytes32 memo) internal {
        MintRequest storage r = mintRequests[requestId];
        if (r.user == address(0)) revert RequestNotFound();
        if (r.status != MintStatus.Pending) revert InvalidRequestStatus();
        if (mintedAmount == 0) revert InvalidAmount();

        r.status = MintStatus.Settled;
        r.mintedAmount = mintedAmount;
        r.settledAt = uint64(block.timestamp);
        r.memo = memo;

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

        stablecoin.safeTransferFrom(r.collectionWallet, r.user, r.stableAmount);

        emit MintRejected(requestId, r.user, r.stableAmount);
    }

    function _settleBurn(uint256 requestId, uint256 payoutAmount, bytes32 memo) internal {
        BurnRequest storage r = burnRequests[requestId];
        if (r.user == address(0)) revert RequestNotFound();
        if (r.status != BurnStatus.Pending) revert InvalidRequestStatus();
        if (payoutAmount == 0) revert InvalidAmount();

        r.status = BurnStatus.Settled;
        r.payoutAmount = payoutAmount;
        r.settledAt = uint64(block.timestamp);
        r.memo = memo;

        _burn(address(this), r.burnAmount);
        stablecoin.safeTransferFrom(r.payoutWallet, r.user, payoutAmount);

        emit BurnSettled(requestId, r.user, r.burnAmount, payoutAmount);
    }

    function _rejectBurn(uint256 requestId, bytes32 memo) internal {
        BurnRequest storage r = burnRequests[requestId];
        if (r.user == address(0)) revert RequestNotFound();
        if (r.status != BurnStatus.Pending) revert InvalidRequestStatus();

        r.status = BurnStatus.Rejected;
        r.settledAt = uint64(block.timestamp);
        r.memo = memo;

        _transfer(address(this), r.user, r.burnAmount);

        emit BurnRejected(requestId, r.user, r.burnAmount);
    }
}
