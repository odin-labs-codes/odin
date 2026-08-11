// Reports deployed bytecode size for this project's contracts against the EIP-170 limit.
//
//   node tools/report-sizes.mjs          # table
//   node tools/report-sizes.mjs --check  # also exit 1 if anything is over the limit
//
// `forge build --sizes` already prints sizes and a margin; what it does not print is the fraction of the
// limit consumed, which is the number that tells you whether there is room for another module.

import {execFileSync} from "node:child_process";
import {readFileSync, readdirSync, statSync} from "node:fs";
import {join} from "node:path";

const EIP170_LIMIT = 24_576;

// Only contracts this project ships. Test mocks and library helpers are not deployed by anyone.
// `BERCRuntimeV1` is the one to watch: a clone cannot add code, so every extension any canonical token
// might want has to fit inside this single deployment, and its headroom is what caps V1's extension count.
const TRACKED = new Set(["ExtendedToken", "ExtendedTokenUpgradeable", "BERCRuntimeV1", "BERCFactoryV1"]);

execFileSync("forge", ["build"], {stdio: "inherit", shell: process.platform === "win32"});

function* artifacts(dir) {
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) yield* artifacts(path);
    else if (entry.endsWith(".json")) yield path;
  }
}

const rows = [];
for (const path of artifacts("out")) {
  let artifact;
  try {
    artifact = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    continue;
  }
  const name = path.split(/[\\/]/).pop().replace(/\.json$/, "");
  if (!TRACKED.has(name)) continue;

  const object = artifact.deployedBytecode?.object;
  if (typeof object !== "string" || object.length <= 2) continue;

  const size = (object.length - 2) / 2;
  rows.push({name, size, pct: (size / EIP170_LIMIT) * 100});
}

rows.sort((a, b) => b.size - a.size);

const width = Math.max(...rows.map((r) => r.name.length), 8);
console.log("");
console.log(`Deployed bytecode vs the EIP-170 limit of ${EIP170_LIMIT.toLocaleString()} bytes`);
console.log("");
console.log(`${"contract".padEnd(width)}  ${"bytes".padStart(7)}  ${"of limit".padStart(9)}  ${"free".padStart(7)}`);
console.log(`${"-".repeat(width)}  ${"-".repeat(7)}  ${"-".repeat(9)}  ${"-".repeat(7)}`);

for (const row of rows) {
  const free = EIP170_LIMIT - row.size;
  console.log(
    `${row.name.padEnd(width)}  ${row.size.toLocaleString().padStart(7)}  ` +
      `${`${row.pct.toFixed(1)}%`.padStart(9)}  ${free.toLocaleString().padStart(7)}`
  );
}
console.log("");

const over = rows.filter((r) => r.size > EIP170_LIMIT);
if (over.length > 0) {
  console.error(`over the limit: ${over.map((r) => r.name).join(", ")}`);
  if (process.argv.includes("--check")) process.exit(1);
}
