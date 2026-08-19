# BERC — a modular token extension framework

Inspired by Solana's Token-2022, built for a chain that has no shared runtime to lean on. *Inspired by* is
the exact claim: this is not compatible with Token-2022 and does not reproduce its semantics. Its fee
extension withholds into the recipient's account and separates the key that configures the fee from the key
that harvests it; BERC moves the fee to a vault immediately, under one `FEE_CONFIG_ROLE`. What is borrowed
is the idea that a token should declare what it does, and that the declaration should come from code an
integrator can check.

Token-2022 gets its guarantees from a program: one piece of code owns every mint, walks each account's TLV
extensions in a fixed order, and no token author can change that order. The EVM has no equivalent. Every
ERC-20 is its own program, and an integrator who wants to know how one behaves has to read its source, or
simulate a transfer and hope the result generalises.

This project is the missing half. Not new capabilities — fee-on-transfer, pausing, freezing and hooks all
exist today — but a way for a token to **say what it does**, in a form that costs one `view` call to read and
is fixed for the life of the deployment.

It covers ERC-20 and ERC-721. The two halves share one vocabulary and nothing else — see
[the non-fungible half](#the-non-fungible-half) for what carries over and what cannot.

> The problem with fee-on-transfer tokens was never the fee. It was that you had to find out by losing money.

---

## The idea in one function

```solidity
uint256 flags = IERC20Behavior(token).behaviorFlags();
```

One word. Every way this token departs from a plain ERC-20. Fixed at deployment — and so safe to cache
forever, unless the token declares `UPGRADEABLE`, which is the vocabulary's way of saying that promise is
only as durable as its upgrade authority.

```solidity
if (flags & BehaviorFlags.FEE_ON_TRANSFER != 0) {
    uint256 willArrive = amountIn - IERC20TransferFee(token).computeFee(sender, pool, amountIn);
    // quote against `willArrive` instead of `amountIn` — and the swap works
}
```

That is half the thesis, and [`test/integration/AmmIntegration.t.sol`](test/integration/AmmIntegration.t.sol)
is the proof: the same pool, the same token, the same 2% fee, and four routers. The one that quotes on
`amountIn` fails with Uniswap V2's `K` error. The three that read the token first all succeed. Nothing about
the token changed between the runs — only whether the integrator could find out in advance.

### The other half: can you believe it?

A declaration is only worth the code that produces it, and a token declaring `0` while charging a fee is
just a token that lied. So the framework also answers the second question, and answers it without asking
the token anything:

```solidity
if (BERCVerification.isClonedFrom(token, BERC_RUNTIME_V1)) {
    // Every answer below comes from the one runtime you vetted and pinned. The token's
    // author had no way to alter it.
}
```

Canonical tokens are EIP-1167 clones of one shared runtime. Those 45 bytes are a fixed prologue, an address
and a fixed epilogue — nowhere to hide behaviour. Match the shape, read the address, compare. One
`EXTCODECOPY`, no external call, no registry to trust, and an answer that can never change afterwards.

That gives integrators three tiers instead of a guess:

| Tier | Established by | Declarations are |
| --- | --- | --- |
| **verified** | bytecode is a clone of a known runtime | **guaranteed** |
| **self-declared** | answers `behaviorFlags()`, own bytecode | **a claim** |
| **unknown** | does not answer | **nothing** — and *not* the same as `0` |

---

## Four layers

**1. Declaration and discovery** — `extensions()`, `hasExtension()`, `extensionData()`, `behaviorFlags()`,
`accountState()`. What is installed, how it is configured, and what that means. The extension set is fixed
at initialisation; individual parameters remain configurable but every change emits `ExtensionConfigured`.

**2. Extension interfaces** — metadata, transfer fee, transfer restriction, non-transferability, transfer
hook, checked transfers. Descriptive names, no draft ERC numbers.

**3. Composable reference implementation** — abstract modules on OpenZeppelin v5 that a token assembles by
inheritance, plus two assembled tokens: one immutable, one behind a UUPS proxy.

**4. Verified runtime** — [`BERCRuntimeV1`](src/runtime/BERCRuntimeV1.sol) and
[`BERCFactoryV1`](src/runtime/BERCFactoryV1.sol). One deployed contract every canonical token clones, so a
token's declarations are produced by code an integrator can check rather than trust.

---

## Extensions

| ID           | Module                                                                              | Declares                | Configurable                              |
| ------------ | ----------------------------------------------------------------------------------- | ----------------------- | ----------------------------------------- |
| `0x1880c1f5` | [`ERC20OnchainMetadata`](src/extensions/ERC20OnchainMetadata.sol)                    | *nothing*               | key/value store, ERC-1046 `tokenURI`      |
| `0xe420f71e` | [`ERC20TransferFee`](src/extensions/ERC20TransferFee.sol)                            | `FEE_ON_TRANSFER`       | rate, absolute cap, vault, exemptions     |
| `0x72fd4318` | [`ERC20TransferRestriction`](src/extensions/ERC20TransferRestriction.sol)            | `PAUSABLE`, `BLOCKLIST` | global pause, per-account freeze          |
| `0x2c0ebf42` | [`ERC20NonTransferable`](src/extensions/ERC20NonTransferable.sol)                    | `NON_TRANSFERABLE`      | *nothing — that is the point*             |
| `0xf71cd3fe` | [`ERC20TransferHook`](src/extensions/ERC20TransferHook.sol)                          | `TRANSFER_HOOK`         | target contract, gas budget               |

And for ERC-721:

| Module                                                                    | Declares                | Configurable                       |
| ------------------------------------------------------------------------- | ----------------------- | ---------------------------------- |
| [`ERC721OperatorRestriction`](src/erc721/ERC721OperatorRestriction.sol)    | `OPERATOR_RESTRICTED`   | allowlist membership, and whether it is enforced |
| [`ERC721TransferRestriction`](src/erc721/ERC721TransferRestriction.sol)    | `PAUSABLE`, `BLOCKLIST` | global pause, per-account freeze    |
| [`ERC721MutableMetadata`](src/erc721/ERC721MutableMetadata.sol)            | `METADATA_MUTABLE`      | base URI, per-token URI, one-way freeze |
| [`ERC721NonTransferable`](src/erc721/ERC721NonTransferable.sol)            | `NON_TRANSFERABLE`      | *nothing — that is the point*      |

IDs are `bytes4(keccak256("erc20.extension.<name>"))`, or `erc721.` for the non-fungible ones — derived
from a name rather than from `type(I).interfaceId`, so adding a view function to an interface does not
silently change every deployed token's identifier. The token type is part of the name, so `nonTransferable`
on an ERC-20 and on an ERC-721 are deliberately different identifiers: the modules hold different storage
and take different arguments, and an integrator resolving one against the wrong token type would read a
configuration that does not exist.

### Behaviour flags

| Bit | Flag               | Value | Meaning                                                       |
| --- | ------------------ | ----- | ------------------------------------------------------------- |
| 0   | `FEE_ON_TRANSFER`  | `1`   | The recipient receives less than the amount named in the call |
| 1   | `REBASING`         | `2`   | `balanceOf` moves without a `Transfer` — *reserved, unused*    |
| 2   | `TRANSFER_HOOK`    | `4`   | Transfers make an external call that can revert them          |
| 3   | `PAUSABLE`         | `8`   | An authority can halt all transfers                           |
| 4   | `BLOCKLIST`        | `16`  | An authority can bar individual accounts                      |
| 5   | `NON_TRANSFERABLE` | `32`  | Transfers always revert; only mint and burn move value        |
| 6   | `UPGRADEABLE`      | `64`  | The code can be replaced, so every other flag can change      |
| 7   | `MINTABLE`         | `128` | An authority can create supply and dilute every holder        |
| 8   | `SEIZABLE`         | `256` | An authority can destroy any account's balance                |
| 9   | `OPERATOR_RESTRICTED` | `512` | ERC-721 only: a transfer can be refused for *who asked*    |
| 10  | `METADATA_MUTABLE` | `1024` | ERC-721 only: an authority can rewrite what a token *is*     |

A flag is set when the extension is **installed**, not when it is currently **active**: a token whose fee
rate is zero still declares `FEE_ON_TRANSFER`, because the authority can raise it. False positives cost an
integrator one defensive branch; false negatives cost them funds.

Bits 0–5 describe the token's own observable behaviour — five of them change what a transfer does, and
`REBASING` shows up instead as a balance that moved with no `Transfer` naming the account. Bits 6–8
describe powers an authority holds, which nothing reveals until they are used. Bit 9 and up are behaviours
only a non-fungible token can have, and a fungible one never sets them. Both reference tokens set
`MINTABLE | SEIZABLE` unconditionally, because `mint` and `burn(from, value)` are on the shared base and
neither is optional. Without those bits a token with no extensions would report `0`, which the vocabulary
defines as indistinguishable from a plain ERC-20, while its supply authority could dilute every holder and
take any balance.

Token-2022's Permanent Delegate is a *partial* analogue of `SEIZABLE`, and the larger power of the two: it
can transfer an arbitrary account's balance as well as burn it, while `SEIZABLE` names only the
destruction.

### Forbidden combinations

| Combination                            | Rejected because                                              |
| -------------------------------------- | -------------------------------------------------------------- |
| `NON_TRANSFERABLE` + `FEE_ON_TRANSFER` | The transfer path is unreachable, so no fee can be charged     |
| `NON_TRANSFERABLE` + `TRANSFER_HOOK`   | The transfer path is unreachable, so no hook can fire          |

Checked in the constructor against [`BehaviorFlags.conflictingPair`](src/libraries/BehaviorFlags.sol) — the
same function an integrator can run against a token they did not deploy. All 32 subsets of the five modules
are deployed in [`ExtensionMatrix.t.sol`](test/ExtensionMatrix.t.sol): the 20 permitted ones must transfer
correctly, the 12 forbidden ones must fail inside their own constructor.

---

## The transfer pipeline

Every balance change passes through one `_update` override, in
[`ERC20ExtensionCore`](src/extensions/ERC20ExtensionCore.sol), which fixes the phase order:

```
1. restriction checks   ← mint and burn arrive with the zero address intact
2. fee collection       ← its own _rawUpdate, its own Transfer event; skipped for mint and burn
3. the transfer itself  ← for value − fee
4. the hook             ← after balances settle, inside a reentrancy guard, under a gas cap
```

The obvious alternative — every module overriding `_update` and calling `super` — is a trap. Execution order
would then fall out of C3 linearisation, so `is Fee, Restriction` and `is Restriction, Fee` would behave
differently. Worse, a fee module has to split a transfer into two balance movements, and both halves would
descend through every module below it: a restriction module would end up screening the fee leg as if it were
a user transfer, against the vault's address and the fee's amount. Freezing the fee vault would break every
transfer on the token, for a reason nobody would think to look for.

Here, modules override *phases* instead. Order is fixed in one readable function, a module cannot change it
by being listed first, and each phase sees the arguments it was designed for.
[`UpdateOrdering.t.sol`](test/UpdateOrdering.t.sol) pins all four observable consequences — including that a
frozen fee vault does not block transfers.

---

## Three deployment shapes

| | [`ExtendedToken`](src/ExtendedToken.sol) | [`ExtendedTokenUpgradeable`](src/ExtendedTokenUpgradeable.sol) | [`BERCRuntimeV1`](src/runtime/BERCRuntimeV1.sol) clone |
| --- | --- | --- | --- |
| deployment | direct | ERC-1967 proxy, UUPS | EIP-1167 clone via the factory |
| tier | self-declared | self-declared | **verified** |
| `UPGRADEABLE` | not declared | declared | not declared, and structurally impossible |
| extensions | metadata, fee, restriction, hook | same | any valid subset of all five, chosen per token |
| storage | ERC-7201 namespaced | ERC-7201 namespaced | ERC-7201 namespaced |

The first two are for tokens that want the framework's structure and are content to be taken at their word.
The third is for tokens that want to be *checked*: no admin slot, no upgrade path, and 45 bytes that can
only ever name one implementation.

`ERC20NonTransferable` is absent from the first two by necessity — it contradicts both the fee and the hook,
so an assembly containing all five would revert in its own constructor. The runtime carries it and gates it
on registration, so a soulbound token is one of the subsets the factory can deploy. It is also exercised by
the matrix tests and by [`NonTransferable.t.sol`](test/NonTransferable.t.sol).

### Authorities

One role per extension, plus one per supply power: `MINT_ROLE` · `SEIZE_ROLE` · `METADATA_ROLE` ·
`FEE_CONFIG_ROLE` · `RESTRICTION_ROLE` · `HOOK_CONFIG_ROLE`, and `UPGRADER_ROLE` on the upgradeable variant.
Minting and seizing are separate because `behaviorFlags()` declares `MINTABLE` and `SEIZABLE` separately,
and a vocabulary finer-grained than the authorities behind it is a vocabulary that misleads. Modules know
nothing about roles — they
call a single `_authorizeExtensionConfig(bytes4)` dispatch, so a different assembly can swap in `Ownable`, a
timelock or a governor without touching them.

**These are operational roles under a replaceable admin, not Token-2022's independent authorities.** The
resemblance is real and the difference is load-bearing, so it is worth being exact about:

| | Token-2022 | here |
| --- | --- | --- |
| Separate key per capability | yes | yes |
| An authority can be renounced permanently | yes | no — `DEFAULT_ADMIN_ROLE` can re-grant anything |
| Mint and seizure are separate | yes | yes — `MINT_ROLE` and `SEIZE_ROLE` |
| Holders enumerable on chain | n/a | no — reconstruct from `RoleGranted` / `RoleRevoked` |

So splitting the keys bounds the damage from one compromised operator, and does not bound what the token's
owner can do. `SEIZE_ROLE` in particular burns from any account, which is a seizure power, and it exists
because a freeze that blocked burning could never be settled (see the flow table in
[`docs/INTEGRATION.md`](docs/INTEGRATION.md)). It also covers burning a balance its own holder controls,
since there is no permissionless self-burn here — a treasury retiring its own tokens holds `SEIZE_ROLE`.

Recommended posture for a deployment anyone else is expected to integrate with:

- `DEFAULT_ADMIN_ROLE` on a multisig behind a timelock, never on an EOA — it is the role that can undo every
  other split;
- each operational role on its own key, which [`script/Deploy.s.sol`](script/Deploy.s.sol) does, asserts,
  and refuses to do to the zero address. That last check has to live in the script: it initialises the token
  with the broadcaster so it can configure it before handing the roles over, so the token's own zero-admin
  guard never sees the addresses that end up holding them, and `grantRole` accepts zero without complaint;
- `UPGRADER_ROLE` on a timelock too, or the `UPGRADEABLE` flag is a warning without a mitigation — or use a
  verified runtime clone, which has no upgrade path at all;
- a two-step admin handover. `AccessControl` grants in one transaction, so a mistyped admin address is
  unrecoverable; `AccessControlDefaultAdminRules` adds the pending-accept step and a delay, and is worth
  swapping in for a deployment that matters. This repository does not, because the reference tokens are
  meant to show the extension mechanics rather than a governance stack.

---

## Measurements

Nothing in this section is estimated.

### Contract size — `node tools/report-sizes.mjs`

| Contract                   | bytes  | of the 24,576 limit | free   |
| -------------------------- | ------ | ------------------- | ------ |
| `ExtendedTokenUpgradeable` | 20,066 | 81.6%               | 4,510  |
| `BERCRuntimeV1`            | 18,076 | 73.6%               | 6,500  |
| `ExtendedToken`            | 15,442 | 62.8%               | 9,134  |
| `BERCNFTRuntimeV1`         | 13,202 | 53.7%               | 11,374 |
| `ExtendedNFT`              | 10,587 | 43.1%               | 13,989 |
| `SoulboundNFT`             | 9,855  | 40.1%               | 14,721 |
| `BERCFactoryV1`            | 4,195  | 17.1%               | 20,381 |
| `BERCNFTFactoryV1`         | 4,075  | 16.6%               | 20,501 |

`BERCRuntimeV1` is the row that constrains the design. A clone cannot add code, so every extension any
canonical token might ever want has to fit inside that one deployment — its 6,500 free bytes are the budget
for everything V1 will ever support, which is why V1 ships the five modules it has and new capability
arrives as a new runtime rather than as an addition to this one.

### Transfer gas — `forge test --match-contract GasTest -vv`

Warm path, both accounts already funded, `gasleft()` delta around the call.

| Configuration                            | gas    | delta from the row above |
| ---------------------------------------- | ------ | ------------------------ |
| OpenZeppelin `ERC20.transfer` (baseline) | 3,906  | —                        |
| `ExtendedToken`, nothing switched on     | 7,464  | +3,558                   |
| `ExtendedToken`, fee active              | 12,671 | +5,207                   |
| `ExtendedToken`, hook installed          | 9,895  | +2,431                   |
| `ExtendedToken`, fee and hook            | 15,102 | —                        |

Reading a token's declarations costs a transfer nothing — none of it is on the transfer path, and there is a
test that pins that. The `+3,558` baseline is the pipeline: phase dispatch plus the registry reads that make
the ordering guarantee possible. On an L2, where the meaningful cost is calldata, that is close to free.
What is not free is the fee and the hook — and those are precisely what `behaviorFlags()` warns about.

### Tests — `forge test`

334 tests, all passing.

| Suite | What it establishes |
| --- | --- |
| [`BackwardCompat`](test/BackwardCompat.t.sol) | With every extension installed and the hook live, the ERC-20 surface is unchanged. With the fee off, indistinguishable from a plain ERC-20; with it on, exactly one difference, and it is the declared one. |
| [`AmmIntegration`](test/integration/AmmIntegration.t.sol) | The naive router fails on `K`; the extension-aware one succeeds three ways, and a fourth that knows nothing about fees succeeds using only a checked transfer. The project's reason for existing. |
| [`Verification`](test/runtime/Verification.t.sol) | Clones of the runtime verify, including ones the factory never made. EOAs, plain ERC-20s, self-declared tokens, clones of other implementations, and 45-byte impostors with one byte changed all fail. |
| [`Factory`](test/runtime/Factory.t.sol) | Forbidden combinations, duplicates and unknown IDs are rejected; the admin ends with every role and the factory with none; deterministic addresses match their prediction and cannot be squatted across deployers. |
| [`Runtime`](test/runtime/Runtime.t.sol) | Uninstalled modules stay inert, `NON_TRANSFERABLE` blocks only tokens that asked for it, and a token cannot be configured into an extension its own `extensions()` denies. |
| [`CheckedTransfer`](test/CheckedTransfer.t.sol) | Fuzzed: either the floor holds or nothing moves. Every transfer-affecting setter advances the configuration epoch, and metadata deliberately does not. |
| [`TransferFee`](test/TransferFee.t.sol) | Fuzzed: `computeFee` equals debited minus credited for any amount; `transferExactOut` delivers exactly, and its input is minimal across the whole `uint256` range including the edges where the uncapped inverse does not fit; `maximumFee` bounds every fee and is reached wherever the rate can produce it. |
| [`IntegrationClient`](test/IntegrationClient.t.sol) | Every read and every transfer `docs/INTEGRATION.md` recommends, written against the interfaces alone — so a function the docs use but the interface never declared fails to compile. |
| [`UpdateOrdering`](test/UpdateOrdering.t.sol) | The four externally observable consequences of the fixed phase order. |
| [`ExtensionMatrix`](test/ExtensionMatrix.t.sol) | All 32 subsets: 20 deploy and transfer as declared, 12 revert at construction. |
| [`SupplyInvariant`](test/invariant/SupplyInvariant.t.sol) | Under arbitrary call sequences: balances sum to `totalSupply`, and declarations never move. |
| [`TransferHook`](test/TransferHook.t.sol) | Reentrancy via both `transfer` and `transferFrom` is rejected; the gas cap is real; a veto rolls back the fee leg too; a hook that returns 500kB cannot push the transfer past its published gas budget. |
| [`FrameworkGuards`](test/FrameworkGuards.t.sol) | The guard rails only a third-party assembly can trip: double registration, registration after sealing, unassigned behaviour bits, a fee module that overcharges. |
| [`Constants`](test/Constants.t.sol) | The published extension IDs and the ERC-7201 slot literals still match their derivations — checked against live storage, so a reordered struct fails too. |
| [`Upgrade`](test/Upgrade.t.sol) | `UPGRADEABLE` is declared; an upgrade carries every declaration and all state across unchanged. |
| [`Gas`](test/Gas.t.sol) | Produces the gas table above, and pins that reading a token's declarations costs its transfer path nothing. |
| [`ExtendedNFT`](test/erc721/ExtendedNFT.t.sol) | The non-fungible existence proof: a marketplace holding a valid approval fails at settlement, and the same marketplace one `view` earlier declines to list. Plus the policy's edges — the owner is never screened, mint and burn are never screened, approval is deliberately not gated. |
| [`ERC721Modules`](test/erc721/ERC721Modules.t.sol) | Pause and freeze on a collection, with the two asymmetries that keep them usable; and metadata rewritten under a holder who never moved, then frozen one-way. |
| [`NFTRuntime`](test/erc721/NFTRuntime.t.sol) | The non-fungible verified tier: collections verify against the runtime with the unchanged library, the two runtimes do not verify against each other, uninstalled modules stay inert, and roles are split inside the deployment. |
| [`ERC721FrameworkGuards`](test/erc721/ERC721FrameworkGuards.t.sol) | The non-fungible guard rails: soulbound combined with an operator policy is rejected at construction, double registration and registration after sealing fail, an installed module with no role mapped authorises nobody, and the ERC-7201 namespaces do not collide with the fungible ones. |

### Coverage — `FOUNDRY_PROFILE=coverage forge coverage --no-match-coverage "^(test|script)/"`

| | lines | statements | branches | functions |
| --- | --- | --- | --- | --- |
| `src/` | **98.57%** | **98.86%** | **96.79%** | **97.70%** |

Nineteen of the twenty-two source files are at 100% of lines, including every non-fungible module, both
runtimes, both factories and `BERCVerification`. Everything uncovered is either unreachable from a public
entry point or an artefact of how coverage attributes forwarding code, and each piece is worth stating:

- the neutral base implementations of `_accountFrozen` and `_accountFeeExempt` in `ERC20ExtensionCore`,
  which every module overrides;
- the final `else` in `ExtendedTokenBase._authorizeExtensionConfig`, now doubly unreachable — the installed
  check in front of it rejects any ID that could have got there;
- the `ERC20ExactOutUnrepresentable` revert in `ERC20TransferFee`, which is unreachable by an argument
  written out at the call site: the three conditions needed to reach it contradict each other.

The first two exist for third-party assemblies that add a module this repository does not ship. The third
is a guard on an arithmetic argument, kept so that editing the comparison it depends on fails loudly
instead of silently returning a wrong number.

One more comes from the non-fungible half. `ExtendedNFT.sol` reports 85.71% of lines, and every uncovered
one is a `super.X()` forwarding override that Solidity requires when two parents declare the same function.
They do execute — the operator policy fires through `ExtendedNFT._checkTransferAllowed`, `tokenURI` resolves
through the metadata module, and `supportsInterface` is asserted directly. solc deduplicates the identical
forwarding bodies shared with the runtime and the test assemblies, so the hits are attributed to one copy
and the others read as cold. It is a measurement artefact, not a gap — and the clearest evidence is that the
figure moved from 50% to 85.71% when more assemblies were added, without a line of `ExtendedNFT.sol`
changing.

---

## The non-fungible half

Half the framework ports to ERC-721 unchanged. The most complicated half does not port at all, and what
replaces it is a sharper case for the whole idea.

**What carries over.** The declaration layer is token-agnostic — `behaviorFlags()`, `extensions()`,
`extensionData()` have the same selectors on both sides, so an integrator holding an unclassified address
can ask before knowing which standard it implements. So is the verified tier: `BERCVerification` compares
45 bytes of EIP-1167 prologue, address and epilogue, and has no opinion about what the implementation
behind them is. `ERC721._update` is a single choke point exactly like the fungible one, so phase order is
fixed in one place here too.

**What cannot.** There is no transfer fee, because withholding 2.5% of token #42 is not a thing that
exists. Everything built on top of the fee goes with it: `computeFee`, the exact-output inverse, and
checked transfers with a `minAmountReceived` floor — the recipient either gets #42 or does not, so there is
no amount to check. A fee could be charged in a *different* asset without touching calldata, but then an
NFT transfer reverts because of a balance in an unrelated contract, and what needs declaring stops being a
rate and becomes "this transfer will pull X of token Y from you". That is a different extension, and it is
why EIP-2981 royalties are advisory rather than enforced.

**What replaces it is better.** A fee shows up when an integrator simulates a transfer. An operator policy
does not. A collection can move perfectly for its owner and refuse every transfer one marketplace attempts,
because the screening is on the **caller** — so simulating the owner's own transfer proves nothing about
the transfer the marketplace will make. It surfaces at settlement, and it looks like a bug in the
marketplace. `ERC721._update` receives the authorising address, which `ERC20._update` never does, so the
policy is enforceable at the choke point and readable one `view` in advance:

```solidity
if (!IERC721OperatorRestriction(collection).isOperatorAllowed(address(this))) {
    // do not list it — rather than find out when the sale settles
}
```

[`test/erc721/ExtendedNFT.t.sol`](test/erc721/ExtendedNFT.t.sol) is the existence proof, in the same shape
as the AMM test: one marketplace holds a valid approval and fails at settlement, and the same marketplace
one call earlier declines to list.

**The other flag worth the call is `METADATA_MUTABLE`.** Every other declaration describes something that
happens when value moves. This one describes something that happens while nothing moves: the token stays in
the same wallet with the same id, and what it *is* changes. Anyone pricing a token rather than merely
holding it — a lender taking it as collateral, an index weighting a collection — is exposed to an authority
that can rewrite the traits underneath them, and there is nothing to simulate. `metadataFrozen()` reports
whether that power has been given up, and because the freeze is one-way it is the only answer in this
framework that never needs re-reading.

**Two reference collections, not one.** `NON_TRANSFERABLE` and `OPERATOR_RESTRICTED` are a forbidden
combination — a collection whose transfers always revert has no operator transfer to screen — so
[`ExtendedNFT`](src/erc721/ExtendedNFT.sol) carries the policy and `SoulboundNFT` carries soulbinding, and
an assembly installing both fails in its own constructor. Pause and freeze are *not* forbidden alongside
soulbinding, because they still govern minting. Both declare `MINTABLE | SEIZABLE` unconditionally, which
on the soulbound one is the useful admission that soulbound here does not mean permanent.

**The verified tier needed no new verification.** [`BERCNFTRuntimeV1`](src/runtime/BERCNFTRuntimeV1.sol) and
[`BERCNFTFactoryV1`](src/runtime/BERCNFTFactoryV1.sol) give collections the same three-tier ladder tokens
have, and `BERCVerification` was not touched to make it work — it reads 45 bytes and compares an address,
and has no opinion about what the code behind that address does. The two runtimes are two pinned addresses
checked by one library call, and
[`test/erc721/NFTRuntime.t.sol`](test/erc721/NFTRuntime.t.sol) pins that a collection does not verify
against the fungible runtime and a token does not verify against the non-fungible one.

**Forked, not shared.** `ERC721ExtensionCore` is a deliberate copy of `ERC20ExtensionCore` rather than a
generic base extracted from it. The registries are the same idea, the pipelines are not, and genericising
the fungible core would have re-opened code that has been through four rounds of review to produce a base
shared in name and forked in substance. What *is* shared is the part with no inheritance in it:
`BehaviorFlags`, `ExtensionIds` and `BERCVerification`.

---

## Design decisions worth arguing with

**Extension IDs are name hashes, not interface IDs.** `type(I).interfaceId` is a hash over selectors, so
adding one view function to an interface changes the ID and breaks every integrator who cached it. An
extension ID has to outlive interface revisions.

**No ERC-165.** Discovery is `extensions()` and `hasExtension()`. Adding ERC-165 alongside would mean two
mechanisms answering the same question, and a token could report them inconsistently. One answer is better
than two that agree most of the time.

**The immutable token is built on the upgradeable libraries.** The modules are written once, against
`ERC20Upgradeable` and ERC-7201 storage, and serve both shells. The alternative — two parallel trees — would
put the transfer pipeline in two places, which is where a divergence would be least visible and most
expensive. `ExtendedToken` has no upgrade function, no admin slot, and calls `_disableInitializers()` in its
constructor; it does not declare `UPGRADEABLE` and the claim is structural, not a promise.

**Sealing is mandatory and its absence is loud.** Until an assembly calls `_sealExtensions()`, every
discovery view reverts. A forgotten seal leaves a token with no discovery surface at all, rather than a
quietly unvalidated one. Checking a flag on the transfer path instead would tax every transfer forever to
catch a mistake that can only be made once.

**The non-transferable error is not named `ERC20NonTransferable`.** An error declared in an interface is in
scope in every contract inheriting it, so an error sharing a name with its module shadows the contract — and
the first place that bites is an `override(...)` list, where the compiler resolves the name to the error and
then reports the contract as missing. It is called `ERC20TransfersNotSupported`.

---

## Layout

```
src/
  interfaces/            IERC20Extensions, IERC20Behavior, IERC20OnchainMetadata,
                         IERC20TransferFee, IERC20TransferRestriction,
                         IERC20NonTransferable, IERC20TransferHook, IERC20AccountState,
                         IERC20CheckedTransfer, IERC721Behavior, IERC721Extensions,
                         IERC721OperatorRestriction
  libraries/             BehaviorFlags, ExtensionIds, BERCVerification — shared by both halves
  extensions/            ERC20ExtensionCore + the five modules
  erc721/                ERC721ExtensionCore, four modules, ExtendedNFT + SoulboundNFT
  runtime/               BERCRuntimeV1 + BERCFactoryV1, BERCNFTRuntimeV1 + BERCNFTFactoryV1
                         — the verified tier, one runtime address per token standard
  ExtendedTokenBase.sol  the shared assembly: selectable modules, one role per authority
  ExtendedToken.sol      immutable reference implementation
  ExtendedTokenUpgradeable.sol   UUPS variant, ERC-7201 namespaced
test/                    unit, fuzz, invariant, integration, runtime, combination matrix
script/Deploy.s.sol      the two self-declared variants, with role redistribution
script/DeployRuntime.s.sol   the runtime, its factory, and a canonical token
script/DeployNFTRuntime.s.sol  the same, for collections
tools/                   size reporter, combination-matrix generator
docs/INTEGRATION.md      for people integrating a token built on this
```

---

## Getting started

```bash
forge install
```

```bash
forge test
```

```bash
node tools/report-sizes.mjs
```

Longer fuzz and invariant runs before tagging anything:

```bash
FOUNDRY_PROFILE=intense forge test
```

The combination matrix is generated. Regenerate after changing a module's overridable members:

```bash
node tools/gen-combinations.mjs
```

---

## Chain requirements

**EIP-1153 transient storage — Cancun or later.** `evm_version = "cancun"` in `foundry.toml`, so the
requirement is not confined to the reentrancy guard that motivated it: solc emits Cancun-era opcodes
throughout, and a pre-Cancun chain would fail on ordinary paths, not only on the guard.

No chain support matrix is published here, because none has been tested — nothing in this repository has
been deployed to any network. Confirming that a target chain implements EIP-1153, and running a smoke
deployment against it, is a step for whoever deploys, not a claim this README is in a position to make.
A chain that does not qualify needs a lower `evm_version` and the storage-slot reentrancy guard in place of
`ReentrancyGuardTransientUpgradeable`, which is a fork of this repository rather than a configuration
switch.

Note that a runtime clone runs the guard on every transfer regardless of whether it installed the hook
extension, because the runtime inherits every module. Gating it on the hook being set was measured and
costs more than it saves — the `SLOAD` exceeds the `TSTORE`/`TLOAD` pair it would skip.

---

## Status

Reference implementation. **Self-audited: four rounds complete, all findings closed. No external audit.**

### The self-audit

Four adversarial rounds against the full source, each one closing its findings before the next began. These
were not read-throughs — every round below found defects that the tests and the type system had not, and
each is now pinned: by a regression test for the first three, and by a CI step that must fail for the
fourth, since a Solidity test cannot reproduce `vm.startBroadcast` sender semantics.

| Round | Focus | Notable finding |
| --- | --- | --- |
| 1 | Transfer pipeline, hook safety | Hook return data was outside the gas budget — a 500 kB return charged the caller 571,547 gas beyond the documented cap |
| 2 | Fee arithmetic, exact-output inverse | `computeAmountInForExactOut` overflowed on valid `uint256` input; the minimal-answer property was proved rather than assumed |
| 3 | Declaration vocabulary, deployment | `behaviorFlags()` described transfers but not authorities, so a token with no extensions reported `0` while its supply key could dilute and burn at will |
| 4 | Scripts, lint gate, doc consistency | `ADMIN=0x0` deployed a token whose every authority — including the one that could fix it — was permanently unreachable |

Standing checks, all green and all reproducible from this repository:

- 238 tests; 98.84% lines, 99.29% statements, 95.05% branches, 98.37% functions on `src/`
- 4 invariants at 131,072 calls each, 0 reverts; fee and checked-transfer fuzzing at 20,000 runs each
- all 32 extension subsets deployed — the 20 permitted must transfer, the 12 forbidden must fail in their
  own constructor
- every deploy script executed in CI, including the cases that must be *rejected*
- `forge lint src --severity high --severity med -D warnings` clean, and it is a gate, not a report

### What the self-audit could not cover

- **The non-fungible half came after it.** All four rounds above examined the ERC-20 code, and the tag
  `v0.1.0-self-audited` marks that commit. Everything under `src/erc721/`, the non-fungible runtime and
  factory, and the `OPERATOR_RESTRICTED` and `METADATA_MUTABLE` flags were written afterwards and have had
  no adversarial round of their own. They have tests, full coverage and a lint gate, which is not the same
  thing — the four rounds above each found defects that tests and types had already passed. Treat the two
  halves as being at different stages of review, because they are.
- **No third-party review.** Every round above was conducted by the same people who wrote the code. That is
  a real limit — a self-audit cannot find the assumption everyone involved shares — and it is the reason
  this section exists rather than a one-word status.
- **No static analysis.** Slither, Aderyn, Echidna and Solhint were not available in the development
  environment and have not been run against any commit.
- **No deployment anywhere.** No runtime exists on a public chain, so there is no canonical address to
  verify against and the EIP-1153 requirement has never been exercised outside a local EVM.

### What that means for you

The code has been audited — thoroughly, and by the people who know it best. It has not been audited by
anyone else, and it has never met a real integrator.

Those two sentences point in opposite directions and both are true. The framework is offered for
integration and for the feedback that integration produces: the failure modes that matter here are the ones
that show up when a real protocol wires a real token into a real pool, and no amount of self-review
substitutes for that. Read it as a well-tested reference implementation whose remaining unknowns are
unknown *because nobody has used it yet* — not as code someone else has signed off on.

If you deploy it, deploy it somewhere you can afford to be wrong first, and treat the runtime address you
pin as a commitment: `BERCVerification` works against whatever address you publish, and the verified tier is
only worth what that one deployment is worth.

The interfaces are deliberately not tied to any draft ERC number, so adopting one later does not require
redeploying anything.

## License

MIT
