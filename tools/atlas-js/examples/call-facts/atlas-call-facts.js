/**
 * Atlas call facts for app-core's `createHistory({ callFacts })`.
 *
 * `wants` asks for a kept entry's call arguments when it is a call to the
 * pinned Atlas. `read` keeps the Atlas fields once, as `atlasFn`, which makes
 * `wants` false for that entry.
 *
 * Contracts are matched by the pinned id only. Argument bytes are rkyv 0.7
 * archives (see README.md); only `set_service` is decoded here.
 */

const CONTRACT_ID = /^[0-9a-f]{64}$/;
const ATLAS_FNS = new Set([
  "set_service",
  "set_guardian",
  "set_timelock",
  "cancel_pending",
  "execute_pending",
  "accept_guardian",
  "init_guardian",
]);

// rkyv 0.7 `ArchivedString` (size_32): 8 bytes, inline up to 7 bytes.
const STRING_BYTES = 8;
const INLINE_CAPACITY = 7;
const CONTRACT_ID_BYTES = 32;
// `SetServiceArgs { name: String, id: ContractId }`, repr(C): 8 + 32 bytes.
const SET_SERVICE_BYTES = STRING_BYTES + CONTRACT_ID_BYTES;

/**
 * A contract ID as 64 lower-case hex digits, or null for anything else.
 *
 * @param {unknown} value
 * @returns {string | null}
 */
export function normalizeContractId(value) {
  if (typeof value !== "string") return null;

  const id = value.trim().toLowerCase();

  return CONTRACT_ID.test(id) ? id : null;
}

/**
 * Bytes from hex text, or null when the text is not whole hex bytes.
 *
 * @param {unknown} text
 * @returns {Uint8Array | null}
 */
export function hexToBytes(text) {
  if (typeof text !== "string" || text.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(text)) return null;

  const out = new Uint8Array(text.length / 2);

  for (let i = 0; i < out.length; i += 1) {
    out[i] = Number.parseInt(text.slice(i * 2, i * 2 + 2), 16);
  }

  return out;
}

/**
 * @param {Uint8Array} bytes
 * @returns {string}
 */
function toHex(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * The name of an archived `String` at `pos`, or null when the bytes do not
 * match rkyv 0.7's layout. Mirrors `string/repr.rs`: the top bit of the last
 * byte marks out-of-line, a signed offset from `pos`.
 *
 * @param {Uint8Array} bytes
 * @param {number} pos
 * @returns {string | null}
 */
function archivedString(bytes, pos) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = bytes[pos + STRING_BYTES - 1];

  if ((tag & 0x80) === 0) {
    const len = tag;

    if (len > INLINE_CAPACITY) return null;

    return decodeUtf8(bytes.subarray(pos, pos + len));
  }

  const len = view.getUint32(pos, true);
  const start = pos + view.getInt32(pos + 4, true);

  // Out-of-line strings are only written for names longer than the inline capacity.
  if (len <= INLINE_CAPACITY || start < 0 || start + len > bytes.length) return null;

  return decodeUtf8(bytes.subarray(start, start + len));
}

/**
 * @param {Uint8Array} bytes
 * @returns {string | null}
 */
function decodeUtf8(bytes) {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

/**
 * `SetServiceArgs` from its archived bytes. The root sits at the end of the
 * archive, as rkyv 0.7 writes it. Null when the bytes don't fit that layout.
 *
 * @param {Uint8Array} bytes
 * @returns {{ name: string, id: string } | null}
 */
export function decodeSetServiceArgs(bytes) {
  if (bytes.length < SET_SERVICE_BYTES) return null;

  const root = bytes.length - SET_SERVICE_BYTES;
  const name = archivedString(bytes, root);

  if (name === null) return null;

  return { name, id: toHex(bytes.subarray(root + STRING_BYTES, root + SET_SERVICE_BYTES)) };
}

/**
 * The fields to keep for one call to Atlas. Always carries `atlasFn`, so the
 * entry is not asked again; `set_service` also keeps its name and id when
 * the arguments decode, and nulls when they don't.
 *
 * @param {{ fnName: string, args: string | null }} call
 * @returns {Record<string, unknown>}
 */
function atlasFactsOf(call) {
  if (call.fnName !== "set_service") return { atlasFn: call.fnName };

  const bytes = hexToBytes(call.args);
  const args = bytes === null ? null : decodeSetServiceArgs(bytes);

  return {
    atlasFn: call.fnName,
    atlasServiceId: args?.id ?? null,
    atlasServiceName: args?.name ?? null,
  };
}

/**
 * @param {{ atlasId: string }} options
 * @returns {{ wants: (entry: Record<string, any>) => boolean, read: (call: { contractId: string, fnName: string, args: string | null }, account: string) => Record<string, unknown> }}
 */
export function atlasCallFacts({ atlasId }) {
  const pinned = normalizeContractId(atlasId);

  if (pinned === null) throw new TypeError("atlasId must be 64 lower-case hex digits");

  return {
    /** @param {Record<string, any>} entry */
    wants(entry) {
      if (!entry || typeof entry !== "object") return false;

      // Before details, an entry names its contract only as `counterparty`.
      const contract = normalizeContractId(entry.contractId ?? entry.counterparty);

      return contract === pinned && entry.atlasFn === undefined;
    },

    /** @param {{ contractId: string, fnName: string, args: string | null }} call */
    read(call) {
      if (normalizeContractId(call?.contractId) !== pinned) return {};

      // Every Atlas call keeps `atlasFn`, even a function not listed here, or `wants` would ask again.
      if (!ATLAS_FNS.has(call.fnName)) return { atlasFn: call.fnName };

      return atlasFactsOf(call);
    },
  };
}
