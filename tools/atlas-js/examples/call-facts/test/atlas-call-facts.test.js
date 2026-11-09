import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  atlasCallFacts,
  decodeSetServiceArgs,
  hexToBytes,
  normalizeContractId,
} from "../atlas-call-facts.js";

// Pinned Atlas id for these tests. Any 64 hex digits will do: nothing here reads the chain.
const ATLAS = "aa".repeat(32);
const OTHER = "bb".repeat(32);
const SERVICE = "0d".repeat(32);

// `SetServiceArgs { name: "treasury-data", id: [0x0d; 32] }`, copied from
// crates/atlas-encoding/tests/layout_goldens.rs (GOLDEN_SET_SERVICE_ARGS_HEX).
const GOLDEN_SET_SERVICE = "74726561737572792d646174610000000d000000f0ffffff" + SERVICE;

/** Archived `SetServiceArgs` with an inline name (up to 7 bytes), hand-built per rkyv 0.7 string/repr.rs */
function inlineSetService(name) {
  const repr = Buffer.alloc(8);

  Buffer.from(name, "utf8").copy(repr, 0);
  repr[7] = Buffer.byteLength(name, "utf8");

  return repr.toString("hex") + SERVICE;
}

/** @param {string} fnName @param {string | null} [args] @param {string} [contractId] */
const call = (fnName, args = null, contractId = ATLAS) => ({ args, contractId, fnName });

describe("hexToBytes and normalizeContractId", () => {
  it("reads whole hex bytes and rejects odd or non-hex text", () => {
    assert.deepEqual([...hexToBytes("00ff")], [0, 255]);
    assert.equal(hexToBytes("0"), null);
    assert.equal(hexToBytes("zz"), null);
    assert.equal(hexToBytes(null), null);
  });

  it("normalises contract ids to lower case and rejects other shapes", () => {
    assert.equal(normalizeContractId(ATLAS.toUpperCase()), ATLAS);
    assert.equal(normalizeContractId("0x" + ATLAS), null);
    assert.equal(normalizeContractId(undefined), null);
  });
});

describe("decodeSetServiceArgs", () => {
  it("decodes the pinned golden archive for atlas-encoding 0.5.0", () => {
    const decoded = decodeSetServiceArgs(hexToBytes(GOLDEN_SET_SERVICE));

    assert.deepEqual(decoded, { id: SERVICE, name: "treasury-data" });
  });

  it("decodes an inline name", () => {
    assert.deepEqual(decodeSetServiceArgs(hexToBytes(inlineSetService("atlas"))), { id: SERVICE, name: "atlas" });
  });

  it("refuses an out-of-line name that would fit inline, as rkyv never writes one", () => {
    const short = GOLDEN_SET_SERVICE.replace("0d000000", "05000000");

    assert.equal(decodeSetServiceArgs(hexToBytes(short)), null);
  });

  it("refuses a name that is not UTF-8", () => {
    const bad = "ff".repeat(13) + GOLDEN_SET_SERVICE.slice(26);

    assert.equal(decodeSetServiceArgs(hexToBytes(bad)), null);
  });

  it("refuses a truncated archive and an out-of-range offset", () => {
    assert.equal(decodeSetServiceArgs(hexToBytes(GOLDEN_SET_SERVICE.slice(0, 60))), null);
    // Offset -2^31: out-of-line, pointing before the start of the archive.
    const far = GOLDEN_SET_SERVICE.replace("f0ffffff", "00000080");

    assert.equal(decodeSetServiceArgs(hexToBytes(far)), null);
  });
});

describe("atlasCallFacts.wants", () => {
  const facts = atlasCallFacts({ atlasId: ATLAS });

  it("asks for an unread kept entry whose contract is the pinned id", () => {
    assert.equal(facts.wants({ contractId: ATLAS, fnName: "set_service" }), true);
  });

  it("asks by counterparty before details, as the history keeps them", () => {
    assert.equal(facts.wants({ counterparty: ATLAS }), true);
    assert.equal(facts.wants({ contractId: OTHER, counterparty: ATLAS }), false);
  });

  it("does not ask for another contract, even one with the same function name", () => {
    assert.equal(facts.wants({ contractId: OTHER, fnName: "set_service" }), false);
  });

  it("stops asking once what it reads is kept", () => {
    const entry = { contractId: ATLAS, fnName: "set_guardian" };
    const kept = { ...entry, ...facts.read(call("set_guardian"), "acc") };

    assert.equal(facts.wants(kept), false);
  });

  it("rejects a malformed pinned id rather than matching nothing", () => {
    assert.throws(() => atlasCallFacts({ atlasId: "atlas" }), TypeError);
  });
});

describe("atlasCallFacts.read", () => {
  const facts = atlasCallFacts({ atlasId: ATLAS });

  it("returns {} for a call to any other contract", () => {
    assert.deepEqual(facts.read(call("set_service", GOLDEN_SET_SERVICE, OTHER), "acc"), {});
  });

  it("matches the pinned id in any letter case", () => {
    assert.deepEqual(facts.read(call("set_service", GOLDEN_SET_SERVICE, ATLAS.toUpperCase()), "acc"), {
      atlasFn: "set_service",
      atlasServiceId: SERVICE,
      atlasServiceName: "treasury-data",
    });
  });

  it("keeps the service name and id for set_service", () => {
    assert.deepEqual(facts.read(call("set_service", GOLDEN_SET_SERVICE), "acc"), {
      atlasFn: "set_service",
      atlasServiceId: SERVICE,
      atlasServiceName: "treasury-data",
    });
  });

  it("keeps nulls, not guesses, when set_service arguments do not decode", () => {
    assert.deepEqual(facts.read(call("set_service", null), "acc"), {
      atlasFn: "set_service",
      atlasServiceId: null,
      atlasServiceName: null,
    });
  });

  it("marks the other listed functions as read without decoding their arguments", () => {
    for (const fnName of ["set_guardian", "set_timelock", "cancel_pending", "execute_pending", "accept_guardian", "init_guardian"]) {
      assert.deepEqual(facts.read(call(fnName, "00ff"), "acc"), { atlasFn: fnName }, fnName);
    }
  });

  it("marks an Atlas function it does not list, so wants stops asking", () => {
    assert.deepEqual(facts.read(call("resolve", "00"), "acc"), { atlasFn: "resolve" });
  });
});
