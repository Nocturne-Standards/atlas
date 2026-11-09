/**
 * Hand-coded rkyv 0.7 (size_32) layouts for the few Atlas shapes the reader
 * needs. Every layout here is pinned by test/fixtures/rkyv-goldens.json, which
 * was produced by the crate itself. A layout change in atlas-encoding breaks
 * those tests on purpose: re-derive the fixture, do not patch the offsets.
 *
 * Replies are read from the end of the buffer, where rkyv puts the root. Every
 * reply here is a fixed-size root with no relative pointers, so only the
 * string argument encoder deals with pointers.
 *
 * @module
 */

import { rawKeyToAccount } from "@dusk-network/networks/account";

const STRING_STRUCT_BYTES = 8;
const STRING_INLINE_MAX = 7;
const ALIGN_U32 = 4;

/** Sizes of the archived roots, as rkyv gives them. */
export const SIZE = Object.freeze({
  OPTION_CONTRACT_ID: 33,
  ACCOUNT: 208,
  OPTION_ACCOUNT: 216,
  PENDING_CHANGE: 216,
  PENDING_VIEW: 224,
  OPTION_PENDING_VIEW: 232,
  U64: 8,
  BOOL: 1,
});

/** Where the key sits in an archived Account: tag at 0, key from byte 8. */
const ACCOUNT_KEY_AT = 8;
const ACCOUNT_KEY_BYTES = 193;
const CONTRACT_ID_BYTES = 32;

/** Option and enum tags, by declaration order. */
const OPTION_NONE = 0;
const OPTION_SOME = 1;
const ACCOUNT_EXTERNAL = 0;
const ACCOUNT_CONTRACT = 1;
const CHANGE_GUARDIAN = 0;
const CHANGE_TIMELOCK = 1;

/**
 * @param {number} value
 * @param {number} multiple
 * @returns {number}
 */
const roundUp = (value, multiple) => Math.ceil(value / multiple) * multiple;

/**
 * @param {Uint8Array} bytes
 * @returns {string}
 */
export const toHex = (bytes) =>
  Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");

/**
 * The archive of a `String` argument. Up to 7 bytes it is stored inline, with
 * the length in the last byte. Longer, the bytes come first and an 8-byte
 * struct (u32 length, i32 offset back to the bytes) is the root.
 *
 * @param {string} text
 * @returns {Uint8Array}
 */
export function encodeString(text) {
  const data = new TextEncoder().encode(text);
  if (data.length <= STRING_INLINE_MAX) {
    return inlineString(data);
  }
  return outOfLineString(data);
}

/**
 * @param {Uint8Array} data
 * @returns {Uint8Array}
 */
function inlineString(data) {
  const out = new Uint8Array(STRING_STRUCT_BYTES);
  out.set(data, 0);
  out[STRING_STRUCT_BYTES - 1] = data.length;
  return out;
}

/**
 * @param {Uint8Array} data
 * @returns {Uint8Array}
 */
function outOfLineString(data) {
  const rootAt = roundUp(data.length, ALIGN_U32);
  const out = new Uint8Array(rootAt + STRING_STRUCT_BYTES);
  const view = new DataView(out.buffer);
  out.set(data, 0);
  view.setUint32(rootAt, data.length, true);
  view.setInt32(rootAt + 4, -rootAt, true);
  return out;
}

/**
 * The offset of a root of `size` bytes, checked against the reply. Fails on a
 * reply too short to hold the root, so a bad read is loud, not a wrong value.
 *
 * @param {Uint8Array} bytes
 * @param {number} size
 * @returns {number}
 */
export function rootOf(bytes, size) {
  if (!(bytes instanceof Uint8Array) || bytes.length < size) {
    throw new RangeError(`rkyv reply is ${bytes?.length ?? "not bytes"}, needs ${size}`);
  }
  return bytes.length - size;
}

/**
 * @param {Uint8Array} bytes
 * @param {number} at
 * @returns {bigint}
 */
const u64At = (bytes, at) =>
  new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getBigUint64(at, true);

/**
 * @param {Uint8Array} bytes
 * @param {number} at
 * @param {number} length
 * @returns {Uint8Array}
 */
const slice = (bytes, at, length) => bytes.subarray(at, at + length);

/**
 * `Option<ContractId>`: null for None, else the id as 64 lower-case hex.
 *
 * @param {Uint8Array} bytes
 * @returns {string | null}
 */
export function decodeOptionContractId(bytes) {
  const root = rootOf(bytes, SIZE.OPTION_CONTRACT_ID);
  const tag = bytes[root];
  if (tag === OPTION_NONE) return null;
  if (tag !== OPTION_SOME) throw new RangeError(`Option tag ${tag}`);
  return toHex(slice(bytes, root + 1, CONTRACT_ID_BYTES));
}

/**
 * An `Account` whose tag byte sits at `at`. External: the 193-byte raw key
 * from byte `at + 8`, returned as a base58 account. Contract: the id from
 * `at + 1`.
 *
 * @param {Uint8Array} bytes
 * @param {number} at
 * @returns {{ type: "external", account: string } | { type: "contract", contractId: string }}
 */
export function decodeAccountAt(bytes, at) {
  const tag = bytes[at];
  if (tag === ACCOUNT_EXTERNAL) {
    const account = rawKeyToAccount(slice(bytes, at + ACCOUNT_KEY_AT, ACCOUNT_KEY_BYTES));
    if (account === null) throw new RangeError("archived guardian key is not a key");
    return { type: "external", account };
  }
  if (tag === ACCOUNT_CONTRACT) {
    return { type: "contract", contractId: toHex(slice(bytes, at + 1, CONTRACT_ID_BYTES)) };
  }
  throw new RangeError(`Account tag ${tag}`);
}

/**
 * `Option<Account>`: null for None (before init_guardian), else the guardian.
 *
 * @param {Uint8Array} bytes
 */
export function decodeOptionAccount(bytes) {
  const root = rootOf(bytes, SIZE.OPTION_ACCOUNT);
  if (bytes[root] === OPTION_NONE) return null;
  if (bytes[root] !== OPTION_SOME) throw new RangeError(`Option tag ${bytes[root]}`);
  return decodeAccountAt(bytes, root + 8);
}

/**
 * `u64` root, as a bigint.
 *
 * @param {Uint8Array} bytes
 * @returns {bigint}
 */
export function decodeU64(bytes) {
  return u64At(bytes, rootOf(bytes, SIZE.U64));
}

/**
 * `bool` root: one byte, 0 or 1. Anything else is a bad reply, not a value.
 *
 * @param {Uint8Array} bytes
 * @returns {boolean}
 */
export function decodeBool(bytes) {
  const byte = bytes[rootOf(bytes, SIZE.BOOL)];
  if (byte > 1) throw new RangeError(`rkyv bool must be 0 or 1, got ${byte}`);
  return byte === 1;
}

/**
 * A `PendingChange` whose tag sits at `at`. Guardian: an Account from `at + 8`.
 * Timelock: the delay from `at + 8`.
 *
 * @param {Uint8Array} bytes
 * @param {number} at
 */
function decodeChangeAt(bytes, at) {
  const tag = bytes[at];
  if (tag === CHANGE_GUARDIAN) {
    return { type: "guardian", guardian: decodeAccountAt(bytes, at + 8) };
  }
  if (tag === CHANGE_TIMELOCK) {
    return { type: "timelock", blocks: u64At(bytes, at + 8) };
  }
  throw new RangeError(`PendingChange tag ${tag}`);
}

/**
 * `Option<PendingView>`: null when nothing is scheduled. Else the change and
 * the block it can execute at. The change is 216 bytes, so execute_at sits
 * at offset 216 of the view.
 *
 * @param {Uint8Array} bytes
 */
export function decodeOptionPendingView(bytes) {
  const root = rootOf(bytes, SIZE.OPTION_PENDING_VIEW);
  if (bytes[root] === OPTION_NONE) return null;
  if (bytes[root] !== OPTION_SOME) throw new RangeError(`Option tag ${bytes[root]}`);
  const view = root + 8;
  return {
    change: decodeChangeAt(bytes, view),
    executeAt: u64At(bytes, view + SIZE.PENDING_CHANGE),
  };
}
