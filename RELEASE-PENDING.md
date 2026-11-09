# Release pending

Status: **`nocturne-atlas-encoding` 0.5.0 is published** (2026-11-09).
`nocturne-atlas-event-decoder` 0.3.0 is published, 0.3.1 adds its README;
`nocturne-atlas` and
`nocturne-atlas-test-proxy` stay `publish = false`. This file is the plan for the crates.io step and the list
to decide on before it. Nothing here is a chain step; contract ids stay in
`CHANGELOG.md` and the public deployments record.

## Crates

| Package | Version | Publish | Why |
|---|---|---|---|
| `nocturne-atlas-encoding` | 0.5.0 | **yes, first** | The only crate other code builds against. Consumers decode calls and events with it, and knot-warden / knot-warden-encoding need it: today they path-depend on a sibling Atlas checkout, so they cannot be published or built from a Knot commit alone until this crate is on crates.io (or Atlas is public and they pin a git `rev`). `no_std`, registry-only dependencies, layouts pinned by goldens. |
| `nocturne-atlas-event-decoder` | 0.3.1 | **yes, second** | Host library for indexers. Its supported versions follow the records it can decode, through 0.6.0. Published after `nocturne-atlas-encoding`; it depends on that crate from the registry. |
| `nocturne-atlas` | 0.6.0 | **no** | The contract. It ships as WASM under a contract id, not as a library; consumers pin the id, and its build depends on the release profile and toolchain pin. Nothing would depend on the crate. |
| `nocturne-atlas-test-proxy` | 0.3.0 | **no, never** | Test fixture. It forwards any call for anyone; deployed and named as guardian it would make Atlas writable by everyone. |

## Publish order

1. `nocturne-atlas-encoding`. Unblocks `knot-warden-encoding` and `knot-warden`
   (switch their `../../../atlas/crates/atlas-encoding` path to the crates.io
   version, then publish them per Knot's own `RELEASE-PENDING.md`).
2. `nocturne-atlas-event-decoder`. Its `atlas-encoding` dependency already
   carries a `version`.

## Open decisions for the release

- [x] **Package name.** Decided 2026-10-28: packages are `nocturne-atlas-*`
      (`nocturne-atlas-encoding`, `nocturne-atlas-event-decoder`, and for
      consistency `nocturne-atlas` and `nocturne-atlas-test-proxy`, which stay
      unpublished). `[lib] name` keeps the Rust paths (`atlas_encoding`, ...)
      and the WASM file names (`atlas.wasm`, `atlas_test_proxy.wasm`);
      consumers write
      `atlas-encoding = { package = "nocturne-atlas-encoding", version = "..." }`.
      Check the names are still free on crates.io right before publishing.
- [x] **Which version goes first.** Decided 2026-11-09: the newest,
      `nocturne-atlas-encoding` 0.5.0. It keeps every 0.4.0 and 0.3.0 layout
      and adds `execute_at` on `PendingCancelled`. Knot's publish prep already
      targets 0.5.
- [ ] **Re-read** each `description` against the published API.

## Flip at publish time

- [x] Set `publish = true` only on the crates being published, in the order
      above. Done for `nocturne-atlas-encoding`.
- [ ] Every dependency has a registry `version` (no `git`). `atlas-encoding`
      depends on `dusk-core =1.7.0`, `rkyv =0.7.46`, `bytecheck =0.6.12`,
      optional `dusk-forge 0.3.0` and `serde 1`: all on crates.io.
- [x] Copy `LICENSE` (Apache-2.0) and `NOTICE` into each published crate
      directory. Done for `nocturne-atlas-encoding`.
- [x] `cargo package -p <crate>` and inspect the file list before the
      first publish. `nocturne-atlas-encoding` 0.5.0 verifies (2026-11-09); the name was free on crates.io.
- [ ] Date the `CHANGELOG.md` section for the versions that ship.
- [ ] README and `docs/versioning.md`: replace the git `rev` pin with the
      crates.io line.

## Still true after publishing

- Testnet only. Not audited yet.
- A crate version is not a contract id. Consumers pin the Atlas id from the
  deployments record and check `guardian()` and `timelock_blocks()` on it.
