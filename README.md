# FundController

`FundController.sol` is an ERC-20 share token and request-based fund operations contract intended for managed vault or fund workflows on **BNB Smart Chain (BSC)** and similar EVM networks.

## Overview

The contract combines three responsibilities:

- Issues ERC-20 fund shares to users after an operator settles mint requests.
- Accepts share burn requests and releases stablecoin payouts after an operator settles burn requests.
- Stores daily statement snapshots, including NAV, share supply, net assets, file hash, and URI metadata.

This is not an automated AMM or DEX contract. User mint and burn requests are queued onchain and finalized by an authorized operator.

## Inheritance

`FundController` inherits from:

- `ERC20`
- `AccessControl`
- `ReentrancyGuard`

It also uses `SafeERC20` for stablecoin transfers.

## Core Roles

- `DEFAULT_ADMIN_ROLE`
  - Updates NAV with `setNav`
  - Updates settlement wallets
- `OPERATOR_ROLE`
  - Settles or rejects mint requests
  - Settles or rejects burn requests
  - Publishes daily statements

## Constructor Parameters

The constructor initializes:

- Share token name and symbol
- Admin address
- Operator address
- Stablecoin address
- Mint collection wallet
- Burn payout wallet
- Initial NAV

The contract reads the stablecoin decimals through `IERC20Metadata` and sets a minimum mint threshold of `100 * 10^decimals`.

## User Flow

### Mint flow

1. A user calls `requestMint(stableAmount)`.
2. Stablecoin is transferred from the user to `mintCollectionWallet`.
3. A pending mint request is recorded onchain.
4. An operator later calls `settleMint` or `batchSettleMint` to mint ERC-20 shares.
5. If needed, an operator can reject the request with `rejectMint` or `batchRejectMint`.

### Burn flow

1. A user calls `requestBurn(burnAmount)`.
2. Fund shares are transferred from the user to the contract.
3. A pending burn request is recorded onchain.
4. An operator later calls `settleBurn` or `batchSettleBurn` to burn shares and release stablecoin payout.
5. If needed, an operator can reject the request with `rejectBurn` or `batchRejectBurn`.

## Daily Statement Functions

The contract stores a daily statement per `statementDate` with:

- `nav`
- `totalShares`
- `netAssets`
- `fileHash`
- `uri`
- `publisher`
- `publishedAt`

Relevant functions:

- `publishDailyStatement`
- `publishDailyStatementAndSetNav`
- `getDailyStatement`
- `hasDailyStatement`

## Key Public State

- `stablecoin`
- `mintCollectionWallet`
- `burnPayoutWallet`
- `nav`
- `nextMintRequestId`
- `nextBurnRequestId`
- `mintRequests`
- `burnRequests`

## Notable Events

- `NavUpdated`
- `MintRequested`
- `MintSettled`
- `MintRejected`
- `BurnRequested`
- `BurnSettled`
- `BurnRejected`
- `DailyStatementPublished`
- `MintCollectionWalletUpdated`
- `BurnPayoutWalletUpdated`

## Important Behavior Notes

- Minting is operator-settled, so `stableAmount` and `mintedAmount` are not automatically tied by formula onchain.
- Burning is operator-settled, so `burnAmount` and `payoutAmount` are also finalized offchain by the operator.
- Rejected mint requests require the collection wallet to be able to transfer stablecoin back to the user.
- Rejected burn requests return held shares from the contract back to the user.
- `decimals()` follows the underlying stablecoin decimals rather than always using `18`.

## Security Considerations

- Administrative and operator permissions are powerful and should be assigned to controlled addresses or multisigs.
- Settlement and rejection logic depends on offchain operational processes and wallet funding.
- The contract uses `nonReentrant` on request and settlement paths, but operational security still depends on correct role management and stablecoin behavior.

## Source

- Contract: [FundController.sol](/Users/gulhi/Projects/ra2/packages/hardhat/contracts/FundController.sol)
