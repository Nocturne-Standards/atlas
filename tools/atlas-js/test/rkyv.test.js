import assert from "node:assert/strict";
import { test } from "node:test";

import { rawKeyToAccount } from "@dusk-network/networks/account";

import golden from "./fixtures/rkyv-goldens.json" with { type: "json" };
import {
  decodeAccountAt,
  decodeOptionAccount,
  decodeOptionContractId,
  decodeOptionPendingView,
  decodeU64,
  encodeString,
  toHex,
} from "../src/rkyv.js";

const fromHex = (hex) => Uint8Array.from(hex.match(/../g) ?? [], (byte) => parseInt(byte, 16));
const archive = (name) => fromHex(golden.archives[name]);
const ID_0D = "0d".repeat(32);
const RAW_KEY = fromHex(golden.rawKey193);
const ACCOUNT = rawKeyToAccount(RAW_KEY);

test("encodeString matches rkyv for inline and out-of-line lengths", () => {
  const cases = {
    "string[0]": "",
    "string[1]": "a",
    "string[7]": "abcdefg",
    "string[8]": "abcdefgh",
    "string[9]": "abcdefghi",
    "string[19]": "native.attested-nav",
  };
  for (const [key, text] of Object.entries(cases)) {
    assert.equal(toHex(encodeString(text)), golden.archives[key], key);
  }
});

test("decodeOptionContractId reads Some and None", () => {
  assert.equal(decodeOptionContractId(archive("opt_id_some")), ID_0D);
  assert.equal(decodeOptionContractId(archive("opt_id_none")), null);
});

test("decodeOptionContractId rejects a short reply and an unknown tag", () => {
  assert.throws(() => decodeOptionContractId(new Uint8Array(10)), RangeError);
  const badTag = archive("opt_id_some").slice();
  badTag[0] = 7;
  assert.throws(() => decodeOptionContractId(badTag), RangeError);
});

test("decodeOptionAccount reads None, an External key and a Contract id", () => {
  assert.equal(decodeOptionAccount(archive("opt_account_none")), null);
  assert.deepEqual(decodeOptionAccount(archive("opt_account_some_external")), {
    type: "external",
    account: ACCOUNT,
  });
  assert.deepEqual(decodeOptionAccount(archive("opt_account_some_contract")), {
    type: "contract",
    contractId: ID_0D,
  });
});

test("the External key round-trips through the networks account form", () => {
  assert.deepEqual(decodeAccountAt(archive("account_external"), 0, undefined).account, ACCOUNT);
});

test("decodeU64 reads the timelock as a bigint", () => {
  assert.equal(decodeU64(archive("u64_30")), 30n);
});

test("decodeOptionPendingView reads None, a timelock and guardian changes", () => {
  assert.equal(decodeOptionPendingView(archive("opt_pending_none")), null);
  assert.deepEqual(decodeOptionPendingView(archive("opt_pending_some_timelock")), {
    change: { type: "timelock", blocks: 86400n },
    executeAt: 100n,
  });
  assert.deepEqual(decodeOptionPendingView(archive("opt_pending_some_guardian_contract")), {
    change: { type: "guardian", guardian: { type: "contract", contractId: ID_0D } },
    executeAt: 100n,
  });
  assert.deepEqual(decodeOptionPendingView(archive("opt_pending_some_guardian_external")), {
    change: { type: "guardian", guardian: { type: "external", account: ACCOUNT } },
    executeAt: 100n,
  });
});
