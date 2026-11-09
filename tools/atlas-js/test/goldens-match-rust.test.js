// Drift gate: the JS layouts are copied from crates/atlas-encoding, so this
// reads that crate's golden strings and fails when a fixture stops matching.
// Rust is the source of truth; fix the fixture and src/rkyv.js, never the Rust.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import golden from "./fixtures/rkyv-goldens.json" with { type: "json" };

const RUST = new URL("../../../crates/atlas-encoding/tests/layout_goldens.rs", import.meta.url);
const source = readFileSync(RUST, "utf8");

function rustGolden(name) {
  const match = source.match(new RegExp(`const ${name}: &str = "([0-9a-f]+)";`));
  assert.ok(match, `${name} not found in layout_goldens.rs`);
  return match[1];
}

// rkyv 0.7 `Option<T>` archives as a one-byte tag, seven bytes of padding,
// then `T` in place (T has alignment 8 here).
const some = (inner) => `01${"00".repeat(7)}${inner}`;

const CASES = [
  ["account_external", "GOLDEN_ACCOUNT_EXTERNAL_HEX", (hex) => hex],
  ["account_contract", "GOLDEN_ACCOUNT_CONTRACT_HEX", (hex) => hex],
  ["opt_account_some_external", "GOLDEN_ACCOUNT_EXTERNAL_HEX", some],
  ["opt_account_some_contract", "GOLDEN_ACCOUNT_CONTRACT_HEX", some],
  ["opt_pending_some_timelock", "GOLDEN_PENDING_VIEW_TIMELOCK_HEX", some],
  ["opt_pending_some_guardian_contract", "GOLDEN_PENDING_VIEW_GUARDIAN_HEX", some],
];

for (const [fixture, constant, wrap] of CASES) {
  test(`fixture ${fixture} equals ${constant}`, () => {
    assert.equal(golden.archives[fixture], wrap(rustGolden(constant)));
  });
}
