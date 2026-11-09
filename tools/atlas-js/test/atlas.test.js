import assert from "node:assert/strict";
import { test } from "node:test";

import { rawKeyToAccount } from "@dusk-network/networks/account";
import { networkFor } from "@dusk-network/networks";

import golden from "./fixtures/rkyv-goldens.json" with { type: "json" };
import { createAtlasReader, guardianArg, nodeRead } from "../src/index.js";
import { encodeString, toHex } from "../src/rkyv.js";

const fromHex = (hex) => Uint8Array.from(hex.match(/../g) ?? [], (byte) => parseInt(byte, 16));
const archive = (name) => fromHex(golden.archives[name]);
const ATLAS_ID = "ab".repeat(32);
const ID_0D = "0d".repeat(32);
const ACCOUNT = rawKeyToAccount(fromHex(golden.rawKey193));
const NET = networkFor(2);

/** A `read` that answers from a table of archives and records every call. */
function mockRead(replies) {
  const calls = [];
  const read = async (contractId, fnName, args) => {
    calls.push({ contractId, fnName, args });
    const reply = replies[fnName];
    if (reply instanceof Error) throw reply;
    return reply;
  };
  return { read, calls };
}

test("guardianArg builds the rkyv bytes of Account::External", () => {
  const bytes = guardianArg(ACCOUNT);
  assert.equal(bytes.length, 208);
  assert.equal(toHex(bytes), golden.archives.account_external);
});

test("guardianArg tag is 0 (External), not the Sozu tag 1 (Contract here)", () => {
  assert.equal(guardianArg(ACCOUNT)[0], 0);
});

test("guardianArg rejects things that are not Dusk accounts", () => {
  assert.throws(() => guardianArg("not-an-account"), TypeError);
  assert.throws(() => guardianArg(""), TypeError);
});

test("createAtlasReader rejects a malformed atlasId and a missing transport", () => {
  const { read } = mockRead({});
  assert.throws(() => createAtlasReader({ net: NET, atlasId: "0x" + ATLAS_ID, read }), TypeError);
  assert.throws(() => createAtlasReader({ net: NET, atlasId: "abc", read }), TypeError);
  assert.throws(() => createAtlasReader({ net: NET, atlasId: ATLAS_ID }), TypeError);
});

test("resolve sends the encoded name and returns the id or null", async () => {
  const { read, calls } = mockRead({ resolve: archive("opt_id_some") });
  const atlas = createAtlasReader({ net: NET, atlasId: ATLAS_ID.toUpperCase(), read });
  assert.equal(await atlas.resolve("native.attested-nav"), ID_0D);
  assert.equal(calls[0].contractId, ATLAS_ID);
  assert.equal(calls[0].fnName, "resolve");
  assert.equal(toHex(calls[0].args), golden.archives["string[19]"]);
  assert.deepEqual(calls[0].args, encodeString("native.attested-nav"));

  const none = mockRead({ resolve: archive("opt_id_none") });
  const empty = createAtlasReader({ net: NET, atlasId: ATLAS_ID, read: none.read });
  assert.equal(await empty.resolve("unknown"), null);
});

test("guardian returns the External key as an account, the Contract id, or null", async () => {
  const external = createAtlasReader({
    net: NET,
    atlasId: ATLAS_ID,
    read: mockRead({ guardian: archive("opt_account_some_external") }).read,
  });
  assert.deepEqual(await external.guardian(), { type: "external", account: ACCOUNT });

  const contract = createAtlasReader({
    net: NET,
    atlasId: ATLAS_ID,
    read: mockRead({ guardian: archive("opt_account_some_contract") }).read,
  });
  assert.deepEqual(await contract.guardian(), { type: "contract", contractId: ID_0D });

  const unset = createAtlasReader({
    net: NET,
    atlasId: ATLAS_ID,
    read: mockRead({ guardian: archive("opt_account_none") }).read,
  });
  assert.equal(await unset.guardian(), null);
});

test("timelockBlocks returns a bigint and calls timelock_blocks with no args", async () => {
  const { read, calls } = mockRead({ timelock_blocks: archive("u64_30") });
  const atlas = createAtlasReader({ net: NET, atlasId: ATLAS_ID, read });
  assert.equal(await atlas.timelockBlocks(), 30n);
  assert.equal(calls[0].fnName, "timelock_blocks");
  assert.equal(calls[0].args.length, 0);
});

test("pending returns the scheduled change and its execute block, or null", async () => {
  const scheduled = createAtlasReader({
    net: NET,
    atlasId: ATLAS_ID,
    read: mockRead({ pending: archive("opt_pending_some_timelock") }).read,
  });
  assert.deepEqual(await scheduled.pending(), {
    change: { type: "timelock", blocks: 86400n },
    executeAt: 100n,
  });

  const idle = createAtlasReader({
    net: NET,
    atlasId: ATLAS_ID,
    read: mockRead({ pending: archive("opt_pending_none") }).read,
  });
  assert.equal(await idle.pending(), null);
});

test("a failing read rejects with the same error", async () => {
  const boom = new Error("node down");
  const atlas = createAtlasReader({
    net: NET,
    atlasId: ATLAS_ID,
    read: mockRead({ timelock_blocks: boom }).read,
  });
  await assert.rejects(atlas.timelockBlocks(), boom);
});

test("without read, fetch builds a node read from net.urls.node", async () => {
  const seen = [];
  const fetch = async (url, init) => {
    seen.push({ url, init });
    return { ok: true, status: 200, arrayBuffer: async () => archive("opt_id_some").buffer };
  };
  const atlas = createAtlasReader({ net: NET, atlasId: ATLAS_ID, fetch });
  assert.equal(await atlas.resolve("native.attested-nav"), ID_0D);
  assert.equal(
    seen[0].url,
    `${NET.urls.node}/on/contracts:${ATLAS_ID}/resolve`,
  );
  assert.equal(seen[0].init.method, "POST");
  assert.deepEqual(seen[0].init.body, encodeString("native.attested-nav"));
});

test("an app read wins over fetch", async () => {
  let fetched = false;
  const fetch = async () => {
    fetched = true;
    throw new Error("should not be called");
  };
  const atlas = createAtlasReader({
    net: NET,
    atlasId: ATLAS_ID,
    read: mockRead({ timelock_blocks: archive("u64_30") }).read,
    fetch,
  });
  assert.equal(await atlas.timelockBlocks(), 30n);
  assert.equal(fetched, false);
});

test("nodeRead turns an HTTP error into a thrown error", async () => {
  const read = nodeRead({
    node: "https://node.example/",
    fetch: async () => ({ ok: false, status: 404, arrayBuffer: async () => new ArrayBuffer(0) }),
  });
  await assert.rejects(read(ATLAS_ID, "pending", new Uint8Array(0)), /HTTP 404/);
});

test("pendingAccepted reads a bool and rejects a byte that is not 0 or 1", async () => {
  const reader = (reply) =>
    createAtlasReader({ net: NET, atlasId: ATLAS_ID, read: mockRead({ pending_accepted: reply }).read });
  assert.equal(await reader(Uint8Array.of(1)).pendingAccepted(), true);
  assert.equal(await reader(Uint8Array.of(0)).pendingAccepted(), false);
  await assert.rejects(reader(Uint8Array.of(2)).pendingAccepted(), RangeError);
  await assert.rejects(reader(new Uint8Array(0)).pendingAccepted(), RangeError);
});
