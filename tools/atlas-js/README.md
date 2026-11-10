# atlas-js

Read-only JavaScript reader for the Atlas registry contract, plus one example. It is a side tool: nothing in the Rust workspace depends on it, and it sends no transactions.

The only dependency is `@dusk-network/networks`, pinned to 0.4.0. Run the tests with `npm ci && npm test`. They use no network.

## API

```js
import { networkFor } from "@dusk-network/networks";
import { createAtlasReader, guardianArg, nodeRead } from "./src/index.js";

const net = networkFor(2); // testnet
const atlas = createAtlasReader({ net, atlasId, read }); // or fetch instead of read

await atlas.resolve("native.attested-nav"); // "<64 hex>" | null
await atlas.guardian(); // { type: "external", account } | { type: "contract", contractId } | null
await atlas.timelockBlocks(); // bigint
await atlas.pending(); // { change: { type: "timelock", blocks } | { type: "guardian", guardian }, executeAt } | null
await atlas.pendingAccepted(); // boolean
guardianArg(account); // Uint8Array, 208 bytes: rkyv Account::External
```

`read` has the Sozu shape: `(contractId, fnName, argBytes) => Promise<Uint8Array>`. An app's `read` always wins. Without one, `fetch` builds a read through `nodeRead({ node: net.urls.node, fetch })`.

## Layouts

The rkyv 0.7 (`size_32`) layouts of `String`, `Option<ContractId>`, `Option<Account>`, `u64`, `bool` and `Option<PendingView>` are hand-coded in `src/rkyv.js`. There is no WASM driver: atlas-encoding's `data-driver` feature only adds serde derives.

`Account::External` archives as tag `0`. Tag `1` is `Account::Contract`. The tag `1` prefix that `@dusk-network/networks/account` documents is Sozu's own convention and does not apply to Atlas.

## Staying in step with the contract

- `test/goldens-match-rust.test.js` reads `crates/atlas-encoding/tests/layout_goldens.rs` and fails when `test/fixtures/rkyv-goldens.json` stops matching it. Rust is the source of truth. CI runs this test, so a layout change in `atlas-encoding` cannot merge without the JS side.
- The read layouts come from `atlas-encoding`'s `call_types.rs`, which has not changed since 0.3.1. Atlas 0.6.0 changed events (`guardian_accepted`, `pending_cancelled.execute_at`) and `set_service` behaviour (`service unchanged`), not the read arguments or replies. So one layout covers the 0.4.1 deployment and the 0.6.0 source.
- Checked against a live node: testnet (chain 2, Rusk 1.7.3) running Atlas 0.4.1 on 2026-11-08. `guardian`, `timelock_blocks`, `pending` and `resolve` of an unknown name decoded to the values the root README records. Not checked live: Atlas 0.6.0, which is not deployed, `resolve` of a name that is set, a non-empty `pending`, and `pendingAccepted`. The 0.6.0 reads are covered by the goldens only.
- Replies are assumed to be exactly the root archive, with no framing. A node that adds framing breaks every read, loudly: a short or malformed reply throws.
- `/on/node/info` needs POST on a Dusk node, not GET.

## Example

`examples/call-facts/` shows Atlas calls in a wallet's activity through app-core's `callFacts` hook. See its README. It is an example, not a supported module.
