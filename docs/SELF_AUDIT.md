# BERC self-audit

**Review date:** 2026-08-21  
**Scope:** `src/`, deployment scripts, and security-relevant tests at the repository state containing
`IBERCAccessControl`  
**Status:** self-review only; no independent audit has been performed

## Executive summary

No critical or high-severity issue was identified in this review. The review added a one-way administration
burn because ordinary OpenZeppelin `renounceRole(DEFAULT_ADMIN_ROLE, ...)` is insufficient when another
admin may exist or when the same admin can restore operational roles before renouncing.

The contracts remain experimental. A self-audit is not an external security audit, and this report does not
claim production fitness. The largest residual risks are privileged configuration, arbitrary external hook
code, UUPS governance, non-enumerable role membership, and the operational requirement to pin the correct
runtime address.

## Method

- Manually traced ERC-20 and ERC-721 transfer, mint, burn, fee, restriction, hook, metadata, factory,
  clone-verification, initialisation, role, and upgrade paths.
- Checked external calls, assembly blocks, role gates, storage namespaces, integer boundaries, deployment
  handover order, and reentrancy boundaries.
- Ran the complete Foundry unit, fuzz, invariant, integration, runtime, and matrix suite.
- Ran `forge lint --severity high`. Slither, Solhint, and Semgrep were not installed in the review
  environment, so this report does not imply coverage by those tools.

## Security properties confirmed

### Initialisation and code identity

- Direct implementations disable initialisers; runtime implementations cannot be initialised directly.
- Factories clone and initialise in one transaction, closing the public-initialiser takeover window.
- Runtime verification compares the full EIP-1167 shape and pinned implementation address without trusting
  the token or a mutable registry.

### Token movement

- The ERC-20 phase order is restriction, fee leg, net leg, hook. A revert in any phase rolls back all legs.
- Hook execution is gas-bounded, return-data copying is capped, and both direct and allowance-based
  reentrancy paths are guarded.
- Fee math uses full-precision multiplication/division, caps fees, and fuzzes exact-output minimality across
  the `uint256` range.
- ERC-721 owner, operator, mint, and burn paths converge on one policy check.

### Access control and the new burn

- `burnAdminPrivileges()` is restricted to `DEFAULT_ADMIN_ROLE`, sets a namespaced one-way bit, disables
  public grant and forced-revoke paths globally, and removes the caller's admin role.
- The lock is contract-wide rather than account-local, so a second admin created before the burn cannot
  bypass it.
- Self-renunciation remains available after the burn. `renounceAllRoles()` covers all built-in ERC-20 and
  ERC-721 roles; the UUPS implementation additionally removes `UPGRADER_ROLE`.
- The state is exposed by `adminPrivilegesBurned()` and by the ERC-165-detectable
  `IBERCAccessControl` interface.

## Findings and residual risks

### SA-01 — UUPS upgrades supersede the administration burn (informational)

`ExtendedTokenUpgradeable` deliberately declares `UPGRADEABLE`. A holder of `UPGRADER_ROLE` can install
code that ignores the burn bit. A deployment that requires immutable authority rules must renounce every
upgrade authority as well, or use an immutable runtime clone. `renounceAllRoles()` removes the caller's
upgrade role but cannot enumerate or remove other holders.

### SA-02 — Existing operational authorities survive the admin burn (informational)

The burn freezes the role layout; it does not silently disable minting, seizure, fees, restrictions,
metadata, hooks, or operator policy. This is intentional so independently held operational keys are not
destroyed by an admin action. Each holder must self-renounce if that capability should disappear.

### SA-03 — Role holders are not enumerable on chain (low / operational)

OpenZeppelin `AccessControl` answers membership for a known account but does not list members. An integrator
must replay `RoleGranted` and `RoleRevoked` events to prove that all operational holders renounced. The
global burn makes `hasRole(DEFAULT_ADMIN_ROLE, account)` false for every account, so this limitation applies
to the operational roles rather than the post-burn admin state.

### SA-04 — Transfer hooks are intentionally arbitrary external code (medium / configuration risk)

A configured hook may revert transfers, consume its published gas budget, inspect token state, or call
other systems. The reentrancy guard and gas/return-data bounds contain direct token-path abuse; they cannot
make a malicious hook benign. Integrators should treat `TRANSFER_HOOK` as an explicit counterparty and
availability risk.

### SA-05 — Privileged behaviours remain economically powerful (medium / design risk)

`MINT_ROLE` can dilute supply, `SEIZE_ROLE` can burn any balance or token, fee configuration can move to the
immutable 10% ceiling, restrictions can block transfers, and mutable NFT metadata can change asset meaning.
These are declared behaviours, not vulnerabilities. Verification proves which code runs; it does not make
the configured policy safe.

### SA-06 — Runtime trust is address-specific (low / integration risk)

A clone is only verified relative to the runtime address the integrator pins. Using an attacker-chosen
runtime address makes the bytecode check meaningless. Runtime addresses must come from trusted deployment
configuration and remain separate for ERC-20 and ERC-721.

## Verification commands

```text
forge test
forge lint --severity high
node tools/report-sizes.mjs
```

The dedicated authority tests are in `test/AdminBurn.t.sol` and cover a pre-existing second admin,
post-burn self-renunciation, atomic ERC-20/ERC-721 role removal, UUPS upgrader removal, ERC-165 discovery,
and unauthorised burn attempts.
