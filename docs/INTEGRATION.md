# Integrating a token built on this framework

You are here because a token you are considering listing, pooling, lending against, or paying with is built
on this framework, and you need to know whether it will behave.

There are two questions, and conflating them is the mistake this document exists to prevent:

1. **What does this token say it does?** One call — `behaviorFlags()` — returns a single word naming every
   way it departs from a plain ERC-20.
2. **Can you believe what it says?** That depends on whether the code producing the answer is code you know.

The second question has a real answer, and it costs one `EXTCODECOPY` and no trust.

---

## 1. Which tier is this token in

| Tier              | How you establish it                                                  | What its declarations are worth                                                                 |
| ----------------- | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| **Verified**      | The token's bytecode is an EIP-1167 clone of a BERC runtime you know   | **Guaranteed.** The answers come from the runtime you vetted; the token's author had no way to alter it. |
| **Self-declared** | It answers `behaviorFlags()`, but the bytecode is its own              | **A claim.** Far better than silence, and worth nothing if the author chose to lie.               |
| **Unknown**       | It does not answer, or its code is unrecognised                        | **Nothing.** Apply whatever policy you already use for arbitrary tokens.                          |

Verification tells you the rules are the published ones. It does not tell you that you will like them: a
verified token can still charge the maximum fee, be paused, and have every holder frozen. Read the flags
afterwards — the point is that now you can believe them.

### A reverting `behaviorFlags()` does not mean "no extensions"

This is the one error worth stating loudly, because the convenient reading is the dangerous one.

```solidity
// WRONG. Do not do this.
try IERC20Behavior(token).behaviorFlags() returns (uint256 f) { flags = f; } catch { flags = 0; }
```

Treating a failed call as `0` collapses "this token declares nothing" into "this token does nothing", and
those are different in two ways that cost money:

- **A token outside this framework can still charge a fee.** Plenty of ERC-20s take a cut and have never
  heard of `behaviorFlags()`. Silence is not a denial.
- **A BERC clone that has not been initialised also reverts** — its extension set is not sealed yet — and
  anyone can initialise it afterwards, with a fee. A `0` you cached today can be wrong tomorrow.

Map the revert to `Unknown` and let your existing policy for unknown tokens handle it.

```solidity
uint256 flags = ...; // only meaningful once you know the tier

if (flags & FEE_ON_TRANSFER != 0)        { /* §5 */ }
if (flags & TRANSFER_HOOK != 0)          { /* §7 */ }
if (flags & (PAUSABLE | BLOCKLIST) != 0) { /* §8 */ }
if (flags & NON_TRANSFERABLE != 0)       { /* §9 — you almost certainly cannot list this */ }
if (flags & UPGRADEABLE != 0)            { /* §10 — everything above can change */ }
if (flags & (MINTABLE | SEIZABLE) != 0)  { /* §11 — an authority can dilute or take balances */ }
```

---

## 2. Verifying the code

Every canonical BERC token is an [EIP-1167](https://eips.ethereum.org/EIPS/eip-1167) minimal proxy pointing
at one shared runtime. Those 45 bytes are a fixed prologue, an address, and a fixed epilogue — there is
nowhere in them to hide behaviour. So if a token's code matches that shape and names a runtime you know,
the token's code *is* that runtime's code.

```solidity
import {BERCVerification} from "berc/libraries/BERCVerification.sol";

/// The runtime address for your chain. Pin it in your deployment config; there is no discovery step.
address constant BERC_RUNTIME_V1 = 0x0000000000000000000000000000000000000000;

if (BERCVerification.isClonedFrom(token, BERC_RUNTIME_V1)) {
    // Verified. behaviorFlags() is produced by the runtime you reviewed and pinned.
}
```

Three properties make this the right check rather than asking a registry:

- **No call and nothing to trust.** A registry is only as honest as its write path; an owner can forge
  entries and an ownerless one can never learn about a second runtime. Bytecode has neither problem, and it
  still works when the registry is unreachable or hostile.
- **The answer never changes.** A minimal proxy contains no `SELFDESTRUCT`, and since EIP-6780 an account
  can only be destroyed in the transaction that created it. Resolve a token once and cache it forever.
- **Provenance is not the claim.** A clone deployed without the canonical factory verifies just the same,
  and should: the guarantee is about which code runs, never about who deployed it.

`BERCFactoryV1` keeps an index (`isDeployedToken`, `tokenAt`, `tokenCount`) — use it to *enumerate* tokens
for a UI, never to decide whether one is safe.

---

## 3. Behaviour flags

Bit values are in [`BehaviorFlags.sol`](../src/libraries/BehaviorFlags.sol). Copy it, or inline the numbers.

| Bit | Flag               | Value | What it means for you                                                        |
| --- | ------------------ | ----- | ---------------------------------------------------------------------------- |
| 0   | `FEE_ON_TRANSFER`  | `1`   | The recipient receives less than the amount you named. §5                     |
| 1   | `REBASING`         | `2`   | `balanceOf` can move without a `Transfer` event. *Reserved; unused today.*    |
| 2   | `TRANSFER_HOOK`    | `4`   | A transfer calls another contract, which can revert it or burn gas. §7        |
| 3   | `PAUSABLE`         | `8`   | An authority can halt all transfers. §8                                       |
| 4   | `BLOCKLIST`        | `16`  | An authority can bar individual accounts. §8                                  |
| 5   | `NON_TRANSFERABLE` | `32`  | Transfers always revert; only mint and burn move value. §9                    |
| 6   | `UPGRADEABLE`      | `64`  | The code can be replaced, so every other row can change. §10                  |
| 7   | `MINTABLE`         | `128` | An authority can create supply and dilute every holder. §11                   |
| 8   | `SEIZABLE`         | `256` | An authority can destroy any account's balance. §11                           |

Bits 0–5 describe the token's own observable behaviour — five of them change what a *transfer* does, and
`REBASING` shows up instead as a balance that moved with no `Transfer` naming the account. Bits 6–8 describe
powers an *authority* holds over the token. The second group will never show up in a simulation, which is
why it has to be declared: both reference tokens can mint without limit and burn from any account, so both
set `MINTABLE | SEIZABLE` even with no extensions installed. A token reporting `0` is claiming it can do
none of this.

Two rules govern the word, and both exist to make caching safe:

- **A flag is set when the extension is installed, not when it is currently active.** A token whose fee rate
  is zero right now still reports `FEE_ON_TRANSFER`, because the authority can raise it. You will
  occasionally take a defensive path you did not need. You will never skip one you did.
- **The word never changes.** Configuration moves; declarations do not. This is checked as an invariant
  across arbitrary call sequences.

`REBASING` is defined but not implemented by any module here. It exists so that the vocabulary is complete —
a token elsewhere can declare it and you can read it with the same code.

---

## 4. Extension IDs

`extensions()` returns the installed set. IDs are `bytes4(keccak256("<name>"))` — derived from a name, not
from an interface's selectors, so adding a view function to an interface does not change the ID.

| ID           | Name                                  | Interface                                                                            |
| ------------ | ------------------------------------- | ------------------------------------------------------------------------------------ |
| `0x1880c1f5` | `erc20.extension.onchainMetadata`     | [`IERC20OnchainMetadata`](../src/interfaces/IERC20OnchainMetadata.sol)                 |
| `0xe420f71e` | `erc20.extension.transferFee`         | [`IERC20TransferFee`](../src/interfaces/IERC20TransferFee.sol)                         |
| `0x72fd4318` | `erc20.extension.transferRestriction` | [`IERC20TransferRestriction`](../src/interfaces/IERC20TransferRestriction.sol)         |
| `0x2c0ebf42` | `erc20.extension.nonTransferable`     | [`IERC20NonTransferable`](../src/interfaces/IERC20NonTransferable.sol)                 |
| `0xf71cd3fe` | `erc20.extension.transferHook`        | [`IERC20TransferHook`](../src/interfaces/IERC20TransferHook.sol)                       |

`extensionData(id)` returns each extension's live configuration, and reverts with `ERC20ExtensionNotEnabled`
if the extension is not installed — so you can tell "installed but unconfigured" from "not installed".

| Extension             | `extensionData` decodes as                                |
| --------------------- | --------------------------------------------------------- |
| `onchainMetadata`     | `(string tokenURI, uint256 keyCount)`                     |
| `transferFee`         | `(uint16 basisPoints, uint256 maximumFee, address vault)` |
| `transferRestriction` | `(bool paused)`                                           |
| `nonTransferable`     | *empty*                                                   |
| `transferHook`        | `(address hook, uint32 gasLimit)`                         |

**Token-level** configuration changes emit `ExtensionConfigured(bytes4 indexed extensionId, bytes data)`
carrying the extension's configuration after the change — the fee rate, cap and vault; the pause flag; the
hook and its budget. Following that one event keeps those current without polling.

Two things it deliberately does not cover, and what to follow instead:

| Not carried by `ExtensionConfigured`   | Follow instead                              | Read back with          |
| -------------------------------------- | ------------------------------------------- | ----------------------- |
| Per-account exemptions and freezes      | `FeeExemptionUpdated`, `AccountFrozen`      | `accountState(account)` |
| Individual metadata entries             | `MetadataUpdated`, `MetadataRemoved`        | `getMetadata(key)`      |

Per-account state is excluded because there is one change per *account* rather than one per token, and
mirroring each into a generic event would double the log cost of every compliance action to repeat what the
typed event already said. Metadata is excluded for the same shape of reason: `extensionData` reports the
token URI and a key count, because an unbounded key/value store does not fit in an event payload.

---

## 5. `FEE_ON_TRANSFER`

### What the token guarantees

- **The sender is always debited exactly the amount named in the call.** `transfer(to, 100)` moves exactly
  100 out of the sender, always. The fee is withheld *from* that 100, never added on top.
- **`computeFee(from, to, amount)` is exact, not an estimate.** In the same transaction, a transfer with
  those arguments withholds precisely that much.
- **`maximumFee()` is an upper bound** over every amount under the **current** configuration, and it is
  reached by any amount at or above `mulDiv(maximumFee(), 10_000, feeBasisPoints(), Rounding.Ceil)` — round
  up, and use `mulDiv` so the product cannot overflow. A cap set beyond what the rate can produce is never
  reached by anything: safe to price against, just looser than it looks.
- **`MAX_FEE_BASIS_POINTS` is the only fee figure no authority can move.** A compile-time constant
  (1000 = 10%). The rate *and the cap* are both authority-mutable; this ceiling is not, so
  `fee <= mulDiv(amount, MAX_FEE_BASIS_POINTS, 10_000)` holds for the life of the deployment no matter what
  the authority does.
- **Mint and burn are never charged.**
- **Both legs are visible as `Transfer` events**: `(from, vault, fee)` then `(from, to, amount - fee)`. An
  indexer summing `Transfer` events sees value conserved.

### Pattern A — ask first (recommended)

```solidity
uint256 fee = IERC20TransferFee(token).computeFee(msg.sender, address(this), amountIn);
uint256 willArrive = amountIn - fee;

// Quote, price, or reserve against `willArrive`, then move the gross amount.
IERC20(token).transferFrom(msg.sender, address(this), amountIn);
```

One `view` call. No balance snapshots, no extra SLOADs on the transfer path, and the number is exact rather
than defensive.

### Pattern B — measure after (the classic)

```solidity
uint256 before = IERC20(token).balanceOf(address(this));
IERC20(token).transferFrom(msg.sender, address(this), amountIn);
uint256 received = IERC20(token).balanceOf(address(this)) - before;
```

Still correct, and still what you must do for tokens outside this framework. Its cost is that you cannot
know `received` before committing to the transfer, so anything that needs a quote up front — a router
comparing paths, a lending market sizing a position — has to either transfer first and unwind on failure, or
guess and add slippage.

### Pattern C — name the output

```solidity
uint256 paid = IERC20TransferFee(token).transferFromExactOut(msg.sender, address(this), 1_000e18);
```

The contract receives exactly `1_000e18`; `paid` is what left the sender. Use this when the arriving number
has to be one *you* chose — matching an off-chain quote, hitting a round tick, settling a fixed obligation.
The input is the smallest one that produces that output, so the sender never overpays by rounding.

Inverting the fee by hand is where integrations go wrong: `out * 10_000 / (10_000 - bps)` is off by one for
most values, and it ignores the cap entirely. The token does it exactly, including across the boundary where
the absolute cap takes over from the rate.

Exact-output fixes the output and floats the **input**, so it needs the opposite guard to §6: a fee raised
between your quote and your inclusion is paid silently by the sender, and `minAmountReceived` cannot see it
because the recipient got exactly what was asked for. Name a ceiling instead:

```solidity
uint256 quoted = IERC20TransferFee(token).computeAmountInForExactOut(msg.sender, address(this), 1_000e18);

uint256 paid = IERC20TransferFee(token).transferFromExactOutChecked(
    msg.sender, address(this), 1_000e18, quoted, 0
);
```

`transferExactOut` and `transferFromExactOut` are these with the ceiling opened all the way, and are the
right choice only when you genuinely do not care what the transfer costs.

Exact-output transfers to yourself revert with `ERC20ExactOutToSelf`. Your balance would fall by the fee and
rise by nothing, so there is no value of `amountOut` the call could honestly deliver.

### Pattern D — price against the immutable ceiling

For a quote that has to stay valid across a configuration change, `maximumFee()` is the wrong number. It is
the *current* cap, and the fee authority can raise the cap exactly as easily as the rate — so a
`maximumFee()` you read last block bounds nothing about this one. Use the constant instead:

```solidity
// MAX_FEE_BASIS_POINTS is compile-time. No authority can move it.
uint256 worstFee = Math.mulDiv(amountIn, IERC20TransferFee(token).MAX_FEE_BASIS_POINTS(), 10_000);
uint256 conservativeIn = amountIn - worstFee;
```

`mulDiv` rather than `amountIn * ceiling / 10_000`, which overflows above roughly a tenth of `uint256`.

This is the pattern for off-chain quote pipelines and batched execution. It is deliberately pessimistic —
it prices every token at the maximum rate the deployment can ever adopt — and that pessimism is what makes
it durable.

`maximumFee()` is still the right figure when you read it in the **same transaction** as the transfer: there
it is a genuine bound on the configuration that is about to execute. Both cases are covered by
`ExtensionAwareRouter` in `test/mocks/MockAmm.sol`, and by a pair of tests that raise the rate *and* the cap
between quote and execution to show which one survives.

### Exemptions

`isFeeExempt(account)` is true when either side of a transfer waives the fee. Pools are the usual case: an
issuer who wants their token to trade normally exempts the pool, and the naive integration path starts
working again. The flag stays set regardless, because the exemption is configuration and can be revoked.

The fee vault is exempt by construction, without needing to be configured.

---

## 6. Checked transfers

Everything in §5 tells you what a transfer will cost *if the configuration holds*. Between the block you
simulated against and the block you land in, a fee authority can raise the rate, and you pay the new one.
Checked transfers close that window by stating your expectation as part of the call.

```solidity
uint256 received = IERC20CheckedTransfer(token).transferChecked(
    to,
    amount,
    minAmountReceived,          // the floor. revert unless at least this much arrives
    0                           // expectedConfigurationEpoch — 0 means "do not check"
);

// Routers, vaults, anything holding an allowance:
uint256 received = IERC20CheckedTransfer(token).transferFromChecked(
    from, to, amount, minAmountReceived, 0
);
```

Both return the recipient's **measured** balance increase, not a predicted one, so the figure is correct
whatever combination of extensions the token installed. The allowance spent by `transferFromChecked` is
`amount` — the gross figure, exactly as `transferFrom` spends it.

### `minAmountReceived` is the guard that matters

There is only one way a transfer goes wrong quietly, and that is less value arriving than you expected.
Everything else a configuration change can do — a blocklist entry, a pause, a swapped hook — makes the
transfer *revert*, which costs you gas and nothing else. So a floor on what arrives is the whole protection,
and it is stated in the one unit that cannot be gamed.

This makes the naive integration safe without knowing anything about fees:

```solidity
// A router that has never heard of computeFee, and is still correct.
uint256 got = IERC20CheckedTransfer(token).transferFromChecked(
    msg.sender, address(this), amountIn, quotedIn, 0
);
```

### The epoch is opt-in, and usually you should not use it

`configurationEpoch()` counts every change that could alter a transfer's outcome — fee rate, vault,
exemptions, pause, freezes, hook. Passing a non-zero `expectedConfigurationEpoch` demands that the
configuration you read is the configuration that executes.

That is a much stronger claim than you usually need, and it fails on changes that have nothing to do with
you: exempting an unrelated address advances the epoch, and an authority touching configuration every block
would make every epoch-checked transfer revert. Reach for it only when you have audited one specific
configuration and will not transact under any other — a treasury operation, not a router.

**And it is a narrower claim than it looks.** The epoch counts setter calls on the token. It does not see:

| Changes what a transfer does | Advances the epoch |
| ----------------------------- | ------------------- |
| Fee, restriction, hook settings on this token | yes |
| The hook contract's own internal state | **no** |
| An upgrade behind the hook, if the hook is a proxy | **no** |
| An upgrade behind the token, on an `UPGRADEABLE` deployment | **no** |

So a matching epoch means *the configuration I read is still installed*, never *the token will behave as it
did*. On an `UPGRADEABLE` token it is worth less again, since an upgrade can change what advancing the epoch
means in the first place. The combination that actually delivers the strong reading is a verified immutable
runtime plus a hook whose code you have read — and even then, `minAmountReceived` is what binds the outcome.

Metadata changes deliberately do **not** advance the epoch. Updating a logo URI cannot change what a
transfer does, and bricking pending transfers over it is what would teach callers to pass `0` forever.

---

## 7. `TRANSFER_HOOK`

The token calls a policy contract after every transfer. Concretely:

- The hook runs **after** balances have settled. It cannot change amounts, only accept or reject the result.
- **A reverting hook reverts the transfer.** Transfers can therefore fail for reasons that have nothing to
  do with balances or allowances. Do not assume a transfer failure means insufficient funds.
- The hook gets exactly `transferHookGasLimit()` gas. **Budget at least that much on top of a plain
  transfer**, plus the 1/64 the EVM withholds from any call — so hold roughly `gasLimit * 64 / 63` spare.
  That figure holds against a hostile hook too: the token copies at most one word of the hook's return
  data and a bounded prefix of any revert reason, so a hook cannot inflate your cost by returning a large
  buffer. There is a test that spends a hook's entire stipend building 500kB and asserts the transfer still
  fits inside the published budget.
- `transferHook()` names the contract, so you can inspect it before integrating.
- The token holds a reentrancy guard for the duration. A hook cannot call back into the transfer path.
- Mint and burn do not fire the hook.

```solidity
if (flags & TRANSFER_HOOK != 0) {
    uint32 budget = IERC20TransferHook(token).transferHookGasLimit();
    require(gasleft() > baseCost + (uint256(budget) * 64) / 63, "insufficient gas for hook");
}
```

---

## 8. `PAUSABLE` and `BLOCKLIST`

The token implements [ERC-1404](https://eips.ethereum.org/EIPS/eip-1404), so existing compliance tooling
works unchanged:

```solidity
uint8 code = IERC20TransferRestriction(token).detectTransferRestriction(from, to, amount);
if (code != 0) {
    // Do not attempt the transfer. Render the reason:
    string memory why = IERC20TransferRestriction(token).messageForTransferRestriction(code);
}
```

Codes are per-token. This framework's reference module uses `0` allowed, `1` paused, `2` sender frozen,
`3` recipient frozen — but render `messageForTransferRestriction` rather than hard-coding anything but `0`.

Restrictions apply to **transfers**, not to supply changes:

| flow                     | paused   | sender frozen         | recipient frozen |
| ------------------------ | -------- | --------------------- | ---------------- |
| transfer (both non-zero) | rejected | rejected              | rejected         |
| mint (`from == 0`)       | allowed  | n/a                   | rejected         |
| burn (`to == 0`)         | allowed  | **allowed** (seizure) | n/a              |

The two asymmetries are deliberate. A pause that also froze supply would strip the authority of its ability
to fix whatever caused the pause. A burn that a freeze blocked would force the issuer to unfreeze before
settling a balance — reopening exactly the window the freeze exists to close.

**What this means for you:** a frozen counterparty's balance can be burned out from under a position you
hold against it. If you are lending against this token, treat `accountState(borrower).frozen` as a
liquidation-relevant signal, not just a transfer-time check.

---

## 9. `NON_TRANSFERABLE`

`transfer` and `transferFrom` always revert with `ERC20TransfersNotSupported`, including for zero amounts and
self-transfers. Only mint and burn move value. `approve` still works and still emits `Approval` — an
allowance on a token that cannot move is inert.

There is no configuration and no way to switch it off. If you run a pool, a market, or anything that has to
move the token to function, this token cannot be listed. That is the point of it declaring so.

---

## 10. `UPGRADEABLE`

The code behind the address can be replaced. Every other guarantee in this document holds only as long as
the upgrade authority allows it.

The framework's own constraint is that **an upgrade must not change the extension set** — registration
happens in the initialiser, which cannot run again, so a new implementation that quietly inherited another
module would run that module's transfer phases while `extensions()` kept reporting the old set. Nothing on
chain can enforce this; it is a governance obligation, and this flag is the warning that the obligation
exists.

If you are integrating with a token that sets this flag, check who holds `UPGRADER_ROLE` and whether it is a
timelock. A `behaviorFlags()` you cached is only as durable as that answer.

A verified token (§2) never sets this flag, and cannot: an EIP-1167 clone has no admin slot and no upgrade
path, so its 45 bytes will name the same runtime forever. That is the difference between a governance
obligation and a structural one, and it is most of the reason the verified tier exists.

---

## 11. Who can do what to this token

The flags tell you what the token *does*. This tells you who can change it, which is the other half of the
question and the one an integrator is more often surprised by.

| Role | Can | Reachable by |
| --- | --- | --- |
| `MINT_ROLE` | Mint without limit — dilutes every holder | `mint` |
| `SEIZE_ROLE` | **Burn from any account**, consent not required | `burn` |
| `FEE_CONFIG_ROLE` | Set the rate, the cap, the vault, per-account exemptions | `setFeeConfig`, `setFeeVault`, `setFeeExempt` |
| `RESTRICTION_ROLE` | Pause all transfers; freeze any account | `setTransfersPaused`, `setFrozen` |
| `HOOK_CONFIG_ROLE` | Install, replace or remove the transfer hook | `setTransferHook` |
| `METADATA_ROLE` | Write the on-chain store and the token URI | `setMetadata`, `removeMetadata`, `setTokenURI` |
| `UPGRADER_ROLE` | Replace the implementation — `UPGRADEABLE` tokens only | `upgradeToAndCall` |
| `DEFAULT_ADMIN_ROLE` | **Grant or revoke every role above, including itself** | `grantRole`, `revokeRole` |

Three consequences worth internalising:

- **The split is operational, not structural.** `DEFAULT_ADMIN_ROLE` can hand itself any other role, so
  "the fee key is separate from the freeze key" limits an operator error, not the owner. Check who holds
  `DEFAULT_ADMIN_ROLE` before you rely on any other separation.
- **`SEIZE_ROLE` can burn a counterparty's balance.** If you lend against this token, a frozen borrower's
  collateral can be burned out from under your position; treat `accountState(borrower).frozen` as a
  liquidation-relevant signal rather than only a transfer-time check. `MINT_ROLE` is a separate key and
  cannot do this — but that is a bound on one compromised operator, not on the issuer.
- **You cannot enumerate role holders.** `hasRole(role, account)` answers about an address you already
  suspect; building the full list means replaying `RoleGranted` and `RoleRevoked`.

`hasRole` is the check to run against a specific address. For a token you are onboarding, the question to
ask its issuer is whether `DEFAULT_ADMIN_ROLE` and `UPGRADER_ROLE` sit behind a timelock.

---

## 12. Per-account state

One call returns every per-account flag the installed extensions maintain, and it is always safe to make —
fields belonging to extensions that are not installed read as `false`, never as a revert.

```solidity
AccountState memory state = IERC20AccountState(token).accountState(account);
// state.frozen        — barred from transferring
// state.feeExempt     — transfers touching this account are not charged
// state.configuredAt  — when any of the above last changed, 0 if never
```

---

## 13. TypeScript / viem

```ts
import { createPublicClient, http, parseAbi, type Address, type Hex } from 'viem'

export const Behavior = {
  FEE_ON_TRANSFER:  1n << 0n,
  REBASING:         1n << 1n,
  TRANSFER_HOOK:    1n << 2n,
  PAUSABLE:         1n << 3n,
  BLOCKLIST:        1n << 4n,
  NON_TRANSFERABLE: 1n << 5n,
  UPGRADEABLE:      1n << 6n,
  MINTABLE:         1n << 7n,
  SEIZABLE:         1n << 8n,
} as const

const abi = parseAbi([
  'function behaviorFlags() view returns (uint256)',
  'function extensions() view returns (bytes4[])',
  'function extensionData(bytes4) view returns (bytes)',
  'function computeFee(address from, address to, uint256 amount) view returns (uint256)',
  'function maximumFee() view returns (uint256)',
  'function isFeeExempt(address) view returns (bool)',
  'function detectTransferRestriction(address from, address to, uint256 amount) view returns (uint8)',
  'function transferHookGasLimit() view returns (uint32)',
])

const client = createPublicClient({ transport: http() })

// An EIP-1167 clone is 45 bytes: prologue, implementation address, epilogue.
const PROLOGUE = '363d3d373d3d3d363d73'
const EPILOGUE = '5af43d82803e903d91602b57fd5bf3'

/** The implementation a minimal proxy delegates to, or null if this is not one. */
export function implementationOf(code: Hex | undefined): Address | null {
  const body = code?.slice(2).toLowerCase()
  if (!body || body.length !== 90) return null
  if (!body.startsWith(PROLOGUE) || !body.endsWith(EPILOGUE)) return null
  return `0x${body.slice(20, 60)}` as Address
}

export type Tier = 'verified' | 'self-declared' | 'unknown'

/**
 * Null means the token did not answer. It does NOT mean zero — see §1. Callers must keep the two apart.
 */
async function tryReadFlags(token: Address): Promise<bigint | null> {
  try {
    return await client.readContract({ address: token, abi, functionName: 'behaviorFlags' })
  } catch {
    return null
  }
}

/**
 * Resolve a token once and cache the result: the tier is fixed by bytecode, and the flags are fixed at
 * deployment. Note that a verified clone that was never initialised still answers nothing, so the flag
 * read decides the tier even when the code check passes.
 */
export async function resolveToken(
  token: Address, runtime: Address,
): Promise<{ tier: Tier; flags: bigint | null }> {
  const [code, flags] = await Promise.all([client.getCode({ address: token }), tryReadFlags(token)])

  if (flags === null) return { tier: 'unknown', flags: null }

  const implementation = implementationOf(code)
  const verified = implementation !== null && implementation === runtime.toLowerCase()
  return { tier: verified ? 'verified' : 'self-declared', flags }
}

export function describe(flags: bigint) {
  return {
    plainErc20: flags === 0n,
    mintable: (flags & Behavior.MINTABLE) !== 0n,
    seizable: (flags & Behavior.SEIZABLE) !== 0n,
    feeOnTransfer: (flags & Behavior.FEE_ON_TRANSFER) !== 0n,
    transferHook: (flags & Behavior.TRANSFER_HOOK) !== 0n,
    restricted: (flags & (Behavior.PAUSABLE | Behavior.BLOCKLIST)) !== 0n,
    nonTransferable: (flags & Behavior.NON_TRANSFERABLE) !== 0n,
    upgradeable: (flags & Behavior.UPGRADEABLE) !== 0n,
  }
}

/** What will actually arrive if `from` sends `amount` to `to`. */
export async function amountThatWillArrive(
  token: Address, flags: bigint, from: Address, to: Address, amount: bigint,
): Promise<bigint> {
  if ((flags & Behavior.FEE_ON_TRANSFER) === 0n) return amount

  const fee = await client.readContract({
    address: token, abi, functionName: 'computeFee', args: [from, to, amount],
  })
  return amount - fee
}

/**
 * Worst case that survives a configuration change, for quotes produced ahead of execution.
 * Built on MAX_FEE_BASIS_POINTS, not maximumFee() — the authority can raise the cap too.
 */
export async function durableWorstCaseArrival(
  token: Address, flags: bigint, amount: bigint,
): Promise<bigint> {
  if ((flags & Behavior.FEE_ON_TRANSFER) === 0n) return amount

  const ceiling = await client.readContract({ address: token, abi, functionName: 'MAX_FEE_BASIS_POINTS' })
  return amount - (amount * BigInt(ceiling)) / 10_000n
}

/** Screen a transfer before submitting it. Returns null when allowed. */
export async function transferBlockedBecause(
  token: Address, flags: bigint, from: Address, to: Address, amount: bigint,
): Promise<number | null> {
  if ((flags & (Behavior.PAUSABLE | Behavior.BLOCKLIST)) === 0n) return null

  const code = await client.readContract({
    address: token, abi, functionName: 'detectTransferRestriction', args: [from, to, amount],
  })
  return code === 0 ? null : code
}
```

---

## 14. Forbidden combinations

Some declarations contradict each other, and a token that made both would be lying about at least one. The
check runs while the token is being initialised — in the constructor for a directly deployed token, in
`initialize` for a clone — and it fails the deployment, so you will never meet one on chain.

| Combination                        | Why it cannot exist                                                |
| ---------------------------------- | ------------------------------------------------------------------ |
| `NON_TRANSFERABLE` + `FEE_ON_TRANSFER` | The transfer path is unreachable, so no fee can ever be charged. |
| `NON_TRANSFERABLE` + `TRANSFER_HOOK`   | The transfer path is unreachable, so no hook can ever fire.     |

Both share one rationale: a declaration that can never manifest is not a harmless extra, it is a false
warning that costs integrators a code path they will never need. The check runs at deployment, against the
same table any integrator can evaluate themselves via `BehaviorFlags.conflictingPair`.

---

## 15. What a transfer actually costs

Measured, not estimated — `test/Gas.t.sol` produces this table with
`forge test --match-contract GasTest -vv`. Warm path, both accounts already funded, `gasleft()` delta around
the call.

| Configuration                                | gas      | delta  |
| -------------------------------------------- | -------- | ------ |
| OpenZeppelin `ERC20.transfer` (baseline)      | 3,906    | —      |
| `ExtendedToken`, nothing switched on          | 7,464    | +3,558 |
| `ExtendedToken`, fee active                   | 12,671   | +5,207 |
| `ExtendedToken`, hook installed               | 9,895    | +2,431 |
| `ExtendedToken`, fee and hook                 | 15,102   | —      |

Reading a token's declarations costs a transfer nothing: `extensions()`, `behaviorFlags()`,
`extensionData()` and `accountState()` are not on the transfer path, and there is a test that pins this.

The `+3,540` baseline overhead is the pipeline itself — the phase dispatch and the registry reads that make
the ordering guarantee possible. On an L2, where the meaningful cost is calldata rather than execution, this
is close to free. What is not free is the fee and the hook, and those are exactly the things
`behaviorFlags()` warns you about before you commit.

---

## 16. Checklist

- [ ] Establish the tier before reading anything else: bytecode against your known runtime for *verified*,
      an answering `behaviorFlags()` for *self-declared*, everything else *unknown*.
- [ ] Never map a reverting `behaviorFlags()` to `0`. A silent token is unclassified, not plain.
- [ ] Read `behaviorFlags()` once and cache it next to the token address.
- [ ] `FEE_ON_TRANSFER`: quote against `computeFee`, or `maximumFee` if the quote must survive a config
      change. Never assume `amount` arrives.
- [ ] Or skip the quote entirely: `transferFromChecked(..., minAmountReceived, 0)` is correct without
      knowing anything about the fee.
- [ ] `TRANSFER_HOOK`: budget `transferHookGasLimit() * 64 / 63` extra gas; expect transfers to be able to
      revert for external reasons.
- [ ] `PAUSABLE` / `BLOCKLIST`: screen with `detectTransferRestriction` before submitting; treat a frozen
      counterparty as a risk signal, because its balance can be burned.
- [ ] `NON_TRANSFERABLE`: do not list.
- [ ] `UPGRADEABLE`: check who holds `UPGRADER_ROLE` before relying on anything above.
- [ ] Check who holds `DEFAULT_ADMIN_ROLE` (§11). It can grant itself every other role, so no other
      separation of keys means anything until you have answered this one.
- [ ] If you lend against the token, treat `SEIZE_ROLE` as able to burn your collateral.
- [ ] `MINTABLE` / `SEIZABLE`: assume supply can grow and balances can vanish without a `transfer` you
      could have screened. Neither is visible in a simulation.
- [ ] For a quote that must outlive a block, price against `MAX_FEE_BASIS_POINTS`, never `maximumFee()`
      — the authority can raise the cap as well as the rate.
- [ ] Follow `ExtensionConfigured` if you need live configuration without polling.
- [ ] Know what "verified" is worth here. The tier proves the token runs *one specific runtime* and cannot
      change it — identity, not quality. The runtime itself is self-audited over four rounds and has had no
      external audit; **Status** in the [README](../README.md) records both halves.
