# atlas-encoding

Host-visible Atlas types: call args and views (`Account`, `InitArgs`,
`SetServiceArgs`, `PendingChange`, `PendingView`) and event payloads
(`atlas_encoding::events`). rkyv layout is pinned by `tests/layout_goldens.rs`.

`no_std` + `alloc`. Builds on host and `wasm32-unknown-unknown`. Feature
`data-driver` turns on serde derives. Feature `contract-events` (off by
default) carries the `ContractEvent` topic impls for the contract macro;
host consumers decoding events do not need it.

atlas-encoding 0.5.0: 0.4.0 plus `execute_at` on `PendingCancelled`
(`atlas` 0.6.0). 0.4.0 added `GuardianAccepted` and kept every 0.3.0 layout.

```toml
atlas-encoding = { package = "nocturne-atlas-encoding", version = "0.5" }
```

A crate version is not a contract id: pin the Atlas contract id from the
deployments record and check `guardian()` and `timelock_blocks()` on it.
