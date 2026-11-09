/**
 * The Atlas reader: `resolve`, `guardian`, `timelockBlocks` and `pending` as
 * permissionless reads, over an app-supplied `read`. The reader never chooses
 * a transport itself; `nodeRead` in index.js is one transport an app can pass.
 *
 * @module
 */

import { accountToRawKey } from "@dusk-network/networks/account";

import {
  SIZE,
  decodeOptionAccount,
  decodeOptionContractId,
  decodeBool,
  decodeOptionPendingView,
  decodeU64,
  encodeString,
} from "./rkyv.js";

/**
 * @typedef {Uint8Array} Bytes
 * @typedef {(contractId: string, fnName: string, args: Bytes) => Promise<Bytes>} Read
 * @typedef {{ urls: { node: string } }} NetworkLike
 */

const ATLAS_ID = /^[0-9a-f]{64}$/;
const NO_ARGS = new Uint8Array(0);

/**
 * `Account::External` is variant 0 in atlas-encoding (declared first), so its
 * rkyv tag is 0 and the key follows at byte 8. The Sozu convention of tag 1 is
 * `Contract` here, so it is not used.
 */
const ACCOUNT_EXTERNAL_TAG = 0;
const ACCOUNT_KEY_AT = 8;
const RAW_KEY_BYTES = 193;

/**
 * The rkyv bytes of `Account::External(key)`, for a guardian argument. 208
 * bytes: tag, padding, the 193-byte raw key, padding. Null-safe: throws on a
 * string that is not a Dusk account.
 *
 * @param {string} account base58 Dusk account
 * @returns {Bytes}
 */
export function guardianArg(account) {
  const raw = accountToRawKey(account);
  if (raw === null || raw.length !== RAW_KEY_BYTES) {
    throw new TypeError("guardianArg needs a Dusk account (base58 BLS key)");
  }
  const out = new Uint8Array(SIZE.ACCOUNT);
  out[0] = ACCOUNT_EXTERNAL_TAG;
  out.set(raw, ACCOUNT_KEY_AT);
  return out;
}

/**
 * @param {unknown} atlasId
 * @returns {string}
 */
function checkAtlasId(atlasId) {
  const id = typeof atlasId === "string" ? atlasId.toLowerCase() : "";
  if (!ATLAS_ID.test(id)) {
    throw new TypeError("atlasId must be 64 hex digits, without 0x");
  }
  return id;
}

/**
 * @param {unknown} net
 * @returns {Read}
 */
function readFromFetch(net, fetch) {
  return async (contractId, fnName, args) => {
    // Lazy import keeps the transport out of the default path. See nodeRead.
    const { nodeRead } = await import("./node-read.js");
    return nodeRead({ node: net.urls.node, fetch })(contractId, fnName, args);
  };
}

/**
 * @param {{ net: NetworkLike, atlasId: string, read?: Read, fetch?: Function }} options
 * @returns {{
 *   atlasId: string,
 *   resolve: (name: string) => Promise<string | null>,
 *   guardian: () => Promise<object | null>,
 *   timelockBlocks: () => Promise<bigint>,
 *   pending: () => Promise<object | null>,
 *   pendingAccepted: () => Promise<boolean>,
 * }}
 */
export function createAtlasReader({ net, atlasId, read, fetch }) {
  const id = checkAtlasId(atlasId);
  const send = chooseRead(net, read, fetch);

  return Object.freeze({
    atlasId: id,
    /** @param {string} name the registered service name; empty or over 64 bytes is never registered */
    resolve: async (name) => decodeOptionContractId(await send(id, "resolve", encodeString(name))),
    guardian: async () => decodeOptionAccount(await send(id, "guardian", NO_ARGS)),
    timelockBlocks: async () => decodeU64(await send(id, "timelock_blocks", NO_ARGS)),
    pending: async () => decodeOptionPendingView(await send(id, "pending", NO_ARGS)),
    pendingAccepted: async () => decodeBool(await send(id, "pending_accepted", NO_ARGS)),
  });
}

/**
 * An app's `read` wins. Without one, `fetch` builds a node read from
 * `net.urls.node`. With neither, there is no way to read, so fail at creation.
 *
 * @param {NetworkLike} net
 * @param {Read | undefined} read
 * @param {Function | undefined} fetch
 * @returns {Read}
 */
function chooseRead(net, read, fetch) {
  if (typeof read === "function") return read;
  if (typeof fetch === "function" && net?.urls?.node) return readFromFetch(net, fetch);
  throw new TypeError("createAtlasReader needs a read function, or fetch and a net with urls.node");
}
