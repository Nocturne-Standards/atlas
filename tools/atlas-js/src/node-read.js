/**
 * A `read` over a Dusk node's HTTP API, with an injected `fetch`.
 *
 * Checked against testnet (chain 2, Rusk 1.7.3) on 2026-11-08: `guardian`,
 * `timelock_blocks`, `pending` and `resolve` (unknown name) decoded to the
 * values the README records for Atlas 0.4.1. The path
 * (`/on/contracts:<id>/<fn>`), octet-stream request and raw rkyv reply work.
 * Not checked: `resolve` for a name that is set, and a pending change.
 * The node's `/on/node/info` needs POST, not GET.
 *
 * @module
 */

/**
 * @param {{ node: string, fetch: (url: string, init: object) => Promise<any> }} options
 * @returns {(contractId: string, fnName: string, args: Uint8Array) => Promise<Uint8Array>}
 */
export function nodeRead({ node, fetch }) {
  const base = node.replace(/\/+$/, "");

  return async (contractId, fnName, args) => {
    const response = await fetch(`${base}/on/contracts:${contractId}/${fnName}`, {
      method: "POST",
      headers: { "content-type": "application/octet-stream" },
      body: args,
    });
    if (!response.ok) {
      throw new Error(`Node read ${fnName} failed with HTTP ${response.status}`);
    }
    return new Uint8Array(await response.arrayBuffer());
  };
}
