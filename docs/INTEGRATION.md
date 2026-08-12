# Integrating a BERC token

This is the guide for the side that did not deploy the token: a router, a vault, a payments backend, an
indexer. It assumes you already refuse fee-on-transfer tokens and want to stop having to.

## The short version

```solidity
uint256 flags = IERC20Behavior(token).behaviorFlags();

if (flags == 0) {
    // Behaves exactly as a plain ERC-20. Nothing below applies.
}
if (flags & BehaviorFlags.FEE_ON_TRANSFER != 0) {
    // Less will arrive than you asked for. Use transferChecked, or quote with computeFee.
}
if (flags & BehaviorFlags.UPGRADEABLE == 0) {
    // The rest of this word is fixed forever. Cache it.
}
```

Three calls, once per token, cached next to the address. Everything else in this document is detail.

## Read the set once

`extensions()`, `hasExtension()` and `behaviorFlags()` are sealed in the constructor and can never change.
That is the whole point of the discovery layer: you resolve a token when you first see it and never re-check.

One exception, and the vocabulary names it: a token declaring `UPGRADEABLE` can have its code replaced, and a
replacement is not bound by the set the old code sealed. Cache such a token's word only as far as you trust
its upgrade authority — or require a verified immutable runtime, which is what `BERCVerification` is for.

## A revert is not an empty set

`extensions()`, `behaviorFlags()` and `extensionData()` all revert with `ERC20ExtensionSetNotSealed` on a
token whose initialiser has not run. Read that as **unknown**, never as "no extensions". A clone that has not
been initialised is inert, but treating its silence as "plain ERC-20" is exactly the mistake the discovery
layer exists to prevent.

## Moving value

Prefer the checked entry points over `transfer` when the token declares anything at all:

```solidity
uint256 received = IERC20CheckedTransfer(token).transferChecked(to, amount, minAmountReceived, 0);
```

`minAmountReceived` is a floor on the recipient's **measured** balance change, so it holds for whatever the
installed extensions do between the two reads — including combinations nobody enumerated. Pass `0` as the
last argument to skip the configuration-epoch check; see below for when the epoch is worth using.

Needing an exact amount to arrive is the other direction, and the fee module inverts its own arithmetic:

```solidity
uint256 amountIn = IERC20TransferFee(token).computeAmountInForExactOut(from, to, amountOut);
IERC20TransferFee(token).transferExactOutChecked(to, amountOut, maxAmountIn, 0);
```

Do not invert the fee yourself. `amountOut * 10_000 / (10_000 - bps)` is off by one for most inputs, and the
absolute cap adds a second branch that is easy to get wrong at the boundary.

## Quoting a fee

`computeFee(from, to, amount)` is exact, not an estimate: within one transaction a transfer withholds
precisely that much. `maximumFee()` bounds it over every amount under the current configuration, and
`MAX_FEE_BASIS_POINTS()` is the compile-time ceiling no authority can move — that is the one to build on if
your quote has to survive a configuration change.

## Screening an account

```solidity
AccountState memory state = IERC20AccountState(token).accountState(account);
```

One call, always safe to make: a field belonging to an extension that is not installed reads as its neutral
value rather than reverting. For the ERC-1404 question — would this specific transfer be rejected, and why —
use `detectTransferRestriction(from, to, amount)` and render `messageForTransferRestriction(code)` rather
than hard-coding any meaning but `0`.

## Budgeting for a hook

A token declaring `TRANSFER_HOOK` calls out to a policy contract after every transfer. `transferHookGasLimit()`
is the published bound; budget at least that much on top of a plain transfer, plus the 1/64 the EVM withholds
from every call. The hook can reject the transfer, so a transfer failing on such a token says nothing about
balances or allowances.

## Following configuration

`ExtensionConfigured(extensionId, data)` carries the extension's whole configuration after every token-level
change, so an indexer following that one event holds a current view without polling. Per-account changes emit
their own typed events instead — `FeeExemptionUpdated`, `AccountFrozen` — because there is one per account
rather than one per token.

## When to use the configuration epoch

`configurationEpoch()` counts setter calls that could change what a transfer does. Passing it back into a
checked transfer demands that the configuration you read is the one that executes.

It is opt-in because it is brittle: exempting an unrelated address bumps it, so an authority that touches
configuration every block would make every epoch-checked transfer revert. Use it when you have audited a
specific configuration and will not transact under any other. Use `minAmountReceived` otherwise.
