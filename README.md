# BERC

A modular ERC-20 extension framework: a token that tells you, in one call, every way it departs from the
ERC-20 you already know.

## The problem

A plain ERC-20 is a promise: `transfer(to, amount)` moves `amount`. Every useful extension breaks it — a fee
means less arrives, a pause means nothing moves, a hook means the call can revert for reasons that have
nothing to do with balances. Protocols respond by refusing anything non-standard, and issuers respond by
hiding it. Neither side is being unreasonable, because there is no way to ask.

Solana's Token-2022 answers this with a runtime: one program owns every mint, extensions are declared on
chain, and a wallet audits the program once instead of auditing each token. This is that idea, on the EVM.

## What a token declares

```solidity
token.extensions();        // the extension ids installed, fixed at deployment
token.hasExtension(id);    // whether one specific extension is installed
token.extensionData(id);   // that extension's current configuration
token.behaviorFlags();     // one word: every departure from plain ERC-20 behaviour
token.accountState(addr);  // every per-account flag the extensions keep
```

The extension set is sealed in the constructor and can never change, so an integrator reads it once and
caches it next to the token address.

## Extensions

| extension | id name | what it does | flags |
| --- | --- | --- | --- |
| `ERC20OnchainMetadata` | `erc20.extension.onchainMetadata` | enumerable key/value metadata plus an ERC-1046 `tokenURI` | none |
| `ERC20TransferFee` | `erc20.extension.transferFee` | pre-computable, hard-capped, invertible fee | `FEE_ON_TRANSFER` |
| `ERC20TransferRestriction` | `erc20.extension.transferRestriction` | ERC-1404 pause and per-account freeze | `PAUSABLE`, `BLOCKLIST` |
| `ERC20TransferHook` | `erc20.extension.transferHook` | gas-bounded call into a policy contract after each transfer | `TRANSFER_HOOK` |
| `ERC20NonTransferable` | `erc20.extension.nonTransferable` | balances mint and burn but never move | `NON_TRANSFERABLE` |

Extension ids are `bytes4(keccak256("erc20.extension.<name>"))` rather than interface ids, so adding a view
function to an interface does not silently change the id an integrator cached.

## Behaviour flags

| bit | flag | meaning |
| --- | --- | --- |
| 0 | `FEE_ON_TRANSFER` | the recipient receives less than the amount named |
| 1 | `REBASING` | `balanceOf` can move with no `Transfer` naming the account |
| 2 | `TRANSFER_HOOK` | a transfer calls into another contract |
| 3 | `PAUSABLE` | transfers can be halted by an authority |
| 4 | `BLOCKLIST` | individual accounts can be barred from transferring |
| 5 | `NON_TRANSFERABLE` | only mint and burn move value |
| 6 | `UPGRADEABLE` | the code can be replaced, so every other flag may change |
| 7 | `MINTABLE` | an authority can create supply |
| 8 | `SEIZABLE` | an authority can destroy any account's balance |

A flag is set when the extension is *installed*, not when it is currently active: a fee extension with its
rate at zero still reports `FEE_ON_TRANSFER`, because the authority can raise it at any time.

Two combinations are rejected at deployment, because `NON_TRANSFERABLE` makes the transfer path unreachable
and any behaviour that only shows up during a transfer is then dead code that still scares integrators away:

- `NON_TRANSFERABLE` with `FEE_ON_TRANSFER`
- `NON_TRANSFERABLE` with `TRANSFER_HOOK`

## Layout

```
src/
  ExtendedToken.sol             immutable reference assembly
  ExtendedTokenUpgradeable.sol  the same assembly behind a UUPS proxy
  ExtendedTokenBase.sol         the shared assembly: four modules, one role per authority
  extensions/                   ERC20ExtensionCore and the five modules
  interfaces/                   the discovery and extension interfaces
  libraries/                    ExtensionIds, BehaviorFlags, BERCVerification
  runtime/                      BERCRuntimeV1 and BERCFactoryV1
```

## Build

```
forge build
forge test
```

Requires a chain with EIP-1153 transient storage: the hook module's reentrancy guard uses `TSTORE`/`TLOAD`.

## Licence

MIT.
