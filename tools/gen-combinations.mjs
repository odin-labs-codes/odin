// Generates test/mocks/Combinations.sol: one concrete token for every subset of the five extension
// modules, so the combination matrix can assert that permitted sets deploy and forbidden sets revert.
//
// Run with:  node tools/gen-combinations.mjs
//
// The output is committed. This script exists because the 32 contracts differ only in their base list
// and in the pass-through overrides Solidity demands for each one, and deriving those by hand 32 times
// is exactly the sort of mechanical work that goes subtly wrong.

import {writeFileSync} from "node:fs";

const CORE = "ERC20ExtensionCore";

const MODULES = [
  {key: "M", name: "ERC20OnchainMetadata", init: "__ERC20OnchainMetadata_init"},
  {key: "F", name: "ERC20TransferFee", init: "__ERC20TransferFee_init"},
  {key: "R", name: "ERC20TransferRestriction", init: "__ERC20TransferRestriction_init"},
  {key: "N", name: "ERC20NonTransferable", init: "__ERC20NonTransferable_init"},
  {key: "H", name: "ERC20TransferHook", init: "__ERC20TransferHook_init"},
];

// For each overridable member, which module carries the most-derived definition. Anything not listed
// inherits the core's definition unchanged, so the core is the definer for that path.
const DEFINERS = {
  _update: {H: "ERC20TransferHook"},
  _checkTransferAllowed: {R: "ERC20TransferRestriction", N: "ERC20NonTransferable"},
  _collectTransferFee: {F: "ERC20TransferFee"},
  _afterTransfer: {H: "ERC20TransferHook"},
  _extensionData: {
    M: "ERC20OnchainMetadata",
    F: "ERC20TransferFee",
    R: "ERC20TransferRestriction",
    H: "ERC20TransferHook",
  },
  _accountFrozen: {R: "ERC20TransferRestriction"},
  _accountFeeExempt: {F: "ERC20TransferFee"},
};

const SIGNATURES = {
  _update: {
    params: "address from, address to, uint256 value",
    mods: "internal virtual",
    returns: "",
    body: "super._update(from, to, value);",
  },
  _checkTransferAllowed: {
    params: "address from, address to, uint256 value",
    mods: "internal view virtual",
    returns: "",
    body: "super._checkTransferAllowed(from, to, value);",
  },
  _collectTransferFee: {
    params: "address from, address to, uint256 value",
    mods: "internal virtual",
    returns: " returns (uint256)",
    body: "return super._collectTransferFee(from, to, value);",
  },
  _afterTransfer: {
    params: "address from, address to, uint256 value",
    mods: "internal virtual",
    returns: "",
    body: "super._afterTransfer(from, to, value);",
  },
  _extensionData: {
    params: "bytes4 extensionId",
    mods: "internal view virtual",
    returns: " returns (bytes memory)",
    body: "return super._extensionData(extensionId);",
  },
  _accountFrozen: {
    params: "address account",
    mods: "internal view virtual",
    returns: " returns (bool)",
    body: "return super._accountFrozen(account);",
  },
  _accountFeeExempt: {
    params: "address account",
    mods: "internal view virtual",
    returns: " returns (bool)",
    body: "return super._accountFeeExempt(account);",
  },
};

/** Bases whose most-derived definition of `member` would collide in a contract inheriting `present`. */
function overrideList(present, member) {
  const definers = new Set(present.map((m) => DEFINERS[member][m.key] ?? CORE));
  if (definers.size < 2) return null;
  const ordered = [CORE, ...MODULES.map((m) => m.name)].filter((n) => definers.has(n));
  return ordered;
}

function contractFor(present) {
  const suffix = present.length === 0 ? "None" : present.map((m) => m.key).join("");
  const name = `Combo_${suffix}`;
  const bases = present.length === 0 ? [CORE] : present.map((m) => m.name);

  const lines = [];
  const label = present.length === 0 ? "no extensions" : present.map((m) => m.name).join(", ");
  lines.push(`/// @dev ${label}.`);
  lines.push(`contract ${name} is ${bases.join(", ")} {`);
  lines.push(`    constructor(string memory name_, string memory symbol_) {`);
  lines.push(`        _initializeCombo(name_, symbol_);`);
  lines.push(`        _disableInitializers();`);
  lines.push(`    }`);
  lines.push(``);
  lines.push(`    function _initializeCombo(string memory name_, string memory symbol_) private initializer {`);
  lines.push(`        __ERC20_init(name_, symbol_);`);
  lines.push(`        __ERC20ExtensionCore_init();`);
  for (const m of present) lines.push(`        ${m.init}();`);
  lines.push(`        _sealExtensions();`);
  lines.push(`    }`);
  lines.push(``);
  lines.push(`    function mint(address to, uint256 value) external {`);
  lines.push(`        _mint(to, value);`);
  lines.push(`    }`);
  lines.push(``);
  lines.push(`    function burn(address from, uint256 value) external {`);
  lines.push(`        _burn(from, value);`);
  lines.push(`    }`);
  lines.push(``);
  lines.push(`    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.`);
  lines.push(`    function _authorizeExtensionConfig(bytes4) internal view override {}`);

  for (const [member, sig] of Object.entries(SIGNATURES)) {
    const list = overrideList(present, member);
    if (!list) continue;
    lines.push(``);
    lines.push(`    function ${member}(${sig.params})`);
    lines.push(`        ${sig.mods}`);
    lines.push(`        override(${list.join(", ")})${sig.returns}`);
    lines.push(`    {`);
    lines.push(`        ${sig.body}`);
    lines.push(`    }`);
  }

  lines.push(`}`);
  return lines.join("\n");
}

const subsets = [];
for (let mask = 0; mask < 1 << MODULES.length; mask++) {
  subsets.push(MODULES.filter((_, i) => mask & (1 << i)));
}

const header = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// GENERATED FILE — do not edit by hand. Regenerate with \`node tools/gen-combinations.mjs\`.
//
// One concrete token for each of the ${subsets.length} subsets of the five extension modules. Names carry the
// modules they contain: M = OnchainMetadata, F = TransferFee, R = TransferRestriction,
// N = NonTransferable, H = TransferHook. \`Combo_None\` has the registry and nothing else.
//
// \`ExtensionMatrixTest\` deploys every one of these from its build artifact, asserts that the permitted
// sets transfer correctly and that the forbidden sets revert inside their own constructor, and checks
// each one's \`behaviorFlags()\` against the modules it actually contains.

import {ERC20ExtensionCore} from "../../src/extensions/ERC20ExtensionCore.sol";
import {ERC20NonTransferable} from "../../src/extensions/ERC20NonTransferable.sol";
import {ERC20OnchainMetadata} from "../../src/extensions/ERC20OnchainMetadata.sol";
import {ERC20TransferFee} from "../../src/extensions/ERC20TransferFee.sol";
import {ERC20TransferHook} from "../../src/extensions/ERC20TransferHook.sol";
import {ERC20TransferRestriction} from "../../src/extensions/ERC20TransferRestriction.sol";
`;

const body = subsets.map(contractFor).join("\n\n");
writeFileSync(new URL("../test/mocks/Combinations.sol", import.meta.url), `${header}\n${body}\n`);
console.log(`wrote ${subsets.length} combination contracts`);
