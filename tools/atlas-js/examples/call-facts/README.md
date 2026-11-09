# call-facts example

A dependency-free JavaScript module that gives app-core's `createHistory({ callFacts })` the Atlas side of a Dusk wallet's activity: which kept entries are calls to Atlas, and what the Atlas calls did. This is an example. Nothing here is wired into a wallet or into app-core.

## Files

- `atlas-call-facts.js`: `atlasCallFacts({ atlasId })` returns `{ wants, read }`, plus the helpers `decodeSetServiceArgs`, `hexToBytes`, `normalizeContractId`.
- `test/atlas-call-facts.test.js`: 18 `node:test` cases, no network.
- No dependencies of its own, so no `@dusk-network/app-core` pin is needed. The parent package's `npm test` runs its tests.

## Contract of the hook

- `wants(entry)` is true when the entry's contract (`contractId`, or `counterparty` before details) is the pinned Atlas id and `entry.atlasFn` is undefined. Contracts are matched by id only, never by name. Ids are compared as lower-case hex.
- `read(call, account)` returns `{}` for any call whose contract is not the pinned id. For a call to Atlas it always returns `atlasFn` (the fnName). That key is what makes `wants` false afterwards. Without it app-core asks for the same call again on every run.
  - `set_service`: also `atlasServiceName` and `atlasServiceId` (hex), decoded from the arguments. Both are `null` when the arguments are missing or don't match the layout.
  - `set_guardian`, `set_timelock`, `cancel_pending`, `execute_pending`, `accept_guardian`, `init_guardian`: `atlasFn` only. Their arguments are not decoded.
  - Any other Atlas function (for example `resolve`): `atlasFn` only, so it is not asked again.

## What is done

- Hook shape, pinned-id matching, and the `wants` / `read` loop closure, covered by tests.
- `set_service` argument decoding for rkyv 0.7 archives (`SetServiceArgs { name: String, id: ContractId }`, repr(C), size_32). Verified against the golden bytes in `crates/atlas-encoding/tests/layout_goldens.rs` (`GOLDEN_SET_SERVICE_ARGS_HEX`) and against a hand-built inline-name archive. Out-of-line names are read from the signed offset; inline names (up to 7 bytes) from the tag byte. Both follow `rkyv-0.7.46/src/string/repr.rs`.
- Refuses, rather than guesses, a non-canonical out-of-line short name, a non-UTF-8 name, a truncated archive, and an offset outside the buffer.

## What is stubbed or not done

- Arguments of the other six functions are not decoded. `set_guardian` and `PendingChange` need rkyv's enum layout (`Account`, `PendingChange`), which is not ported.
- No event decoding. The Rust `atlas-event-decoder` is not ported.
- The pinned id is taken from the caller. It is not checked against the deployments manifest.
- Not run against a live archive or a real Atlas transaction. The only data is the golden bytes.
- Not run inside app-core. Its own `createHistory` tests were not executed here.
- No check of `success`. A failed call still gets its `atlasFn` kept, which is intended, but the wallet must read `success` from the entry itself.

## Assumptions to confirm before wiring

1. `call.args` is hex text with no `0x`. The evidence is app-core's test fixtures (`test/history-details.test.js`, `callData.data: "00ff"`) and the GraphQL `data` field requested by `detailsQuery` (`src/history.js:899-903`). No live response was checked.
2. `call.args` is the exact rkyv archive of the function's argument struct, with no framing. `crates/atlas-encoding/examples/resolve_arg.rs` encodes call arguments with `rkyv::to_bytes::<_, 256>` for the same purpose, which supports this.

## Drift risk when porting the Rust event decoder to JS

- The layouts are rkyv 0.7.46 with `size_32`. A rkyv bump, a `size_64` build, or a change in `atlas-encoding`'s struct fields changes offsets and sizes silently. The JS side hard-codes 4-byte lengths and offsets. Only the golden vectors catch this, so copy them into the JS tests and regenerate both sides together.
- Behaviour depends on the deployment record version, which is not in the bytes. `pending_cancelled` gains `execute_at` from 6000, and `guardian_accepted` exists only from 5000. The Rust decoder checks `SUPPORTED_VERSIONS`. A JS port must receive the version and make the same choice, or it will read old records with the new layout.
- Enum layouts (`Account`, `PendingChange`) are where hand-porting goes wrong: the discriminant width and the padding are chosen by rkyv. Nothing here decodes them yet, which is why those calls are marked unread.
- app-core catches exceptions from `wants` and `read` (`src/history.js:946-951` for `read`, `1040-1044` for `wanted`) and treats them as `false` and `{}`. A bug in a port would therefore show up as entries never filled in, not as an error. Keep `read` from throwing, and check the decoded output against golden vectors.
- A positive rkyv offset has its top byte clear, so it reads as inline. rkyv writes string data before the struct, so offsets are negative. The code relies on that; a layout that writes strings after the root would be misread.
