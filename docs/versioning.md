# Versioning policy

Atlas ships **testnet-only** contracts today. There is no mainnet deployment
claim in this repo.

## Per-crate semver

Each workspace crate carries its own `version` in `Cargo.toml`:

| Package | Rust path / WASM | Version | Published |
|---|---|---|---|
| `nocturne-atlas-encoding` | `atlas_encoding` | 0.5.0 | git only for now (`publish = false`); crates.io planned, see `RELEASE-PENDING.md` |
| `nocturne-atlas` | `atlas`, `atlas.wasm` | 0.6.0 | never (`publish = false`, deployed as WASM) |
| `nocturne-atlas-event-decoder` | `atlas_event_decoder` | 0.3.0 | not yet (`publish = false`; host library) |
| `nocturne-atlas-test-proxy` | `atlas_test_proxy`, `atlas_test_proxy.wasm` | 0.3.0 | never (`publish = false`, test fixture) |

Packages are named `nocturne-atlas-*` (the same pattern as Knot's
`nocturne-knot-*`). Each sets `[lib] name`, so the Rust path and the built
WASM file keep the short name: depend on it as
`atlas-encoding = { package = "nocturne-atlas-encoding", ... }` and write
`use atlas_encoding::...`. Use `-p nocturne-atlas-encoding` (and so on) with
cargo. Commits before the rename name the package `atlas-encoding`; a `rev`
pin to such a commit needs `package = "atlas-encoding"`.

The crate version is the source of truth for that crate's API and, for
`atlas`, for the WASM artifact. Crates version independently; an
`atlas-encoding` bump does not force an `atlas` bump unless the contract
actually changed.

## Git tag or rev

Consumers pin `atlas-encoding` via git, by full commit:

```toml
atlas-encoding = { git = "https://github.com/Nocturne-Standards/atlas", rev = "<40-hex commit>", package = "nocturne-atlas-encoding" }
```

Tags are not signed and can be moved, and a fresh resolution follows the tag,
so `rev` is the pin; a tag only names a commit. The tree is `atlas` 0.6.0
and requires `dusk-core =1.7.0`. `atlas-encoding` 0.5.0 adds `execute_at` to
`PendingCancelled`. 0.4.0 added `GuardianAccepted` and kept every 0.3.0
layout. Older tags are history and
pin older `dusk-core` versions. Sign release tags (`git tag -s`) and
protect `v*` tags once the repository is transferred. See
[`docs/consumers.md`](consumers.md) for what to verify before pinning an id.
A repo tag is an operator-chosen bundle of crate versions at a
point in time; check the tag's `Cargo.toml` files for the exact crate
versions you are building against. When `atlas-encoding` reaches crates.io
the git line becomes a plain version requirement.

## Toolchain pin

`rust-toolchain.toml` pins Rust 1.94.0. This is part of the wire format, not
only a build convenience: the rkyv layout goldens in
`crates/atlas-encoding/tests/layout_goldens.rs` were produced with it.
Bumping the toolchain requires re-running the goldens before any deploy that
follows.

The `[profile.release]` in the root `Cargo.toml` (`opt-level = "z"`, LTO, one
codegen unit) is pinned the same way. It decides the deployed WASM, so a change
there is a bytecode change and needs a redeploy. The deployed WASM is also
run through `wasm-opt -Oz --strip-debug` from binaryen **version 116**.
`make release-wasm` does a clean build with that step required and the version
checked; it prints the `sha256` to record as `wasm_sha256`. A plain `make wasm`
without `wasm-opt` still builds for tests but warns that the result must not be
deployed.

**The deploy artifact is the Linux amd64 build.** The compiler orders functions
differently on a macOS host, so a Mac build of the same commit has a different
hash (measured: 101,309 against 101,313 bytes). Linux builds agree across
environments: the CI `release-wasm` job and `scripts/release-wasm-docker.sh`
(a `rust` container, Cargo home outside `$HOME`, different checkout path)
produced the same hash. Deploy the `atlas-wasm` artifact from the CI
`release-wasm` job, or run the script on the release commit, and record that
hash. Source paths in the binary are remapped (Cargo home, sysroot, workspace
root) so the path of the build does not matter.

## Dependency patch

The root `Cargo.toml` has `[patch."https://github.com/dusk-network/rusk"]`
redirecting `dusk-core` to the registry at `=1.7.0`. knot-encoding at rev
`f391c92` (our pin: knot main after the v0.3.0 release prep) still names the rusk git source, so without
the patch the graph would hold two `dusk-core` versions. Consumers that pin
`atlas-encoding` by git tag and `knot-encoding` by `v0.2.0` need the same patch
until knot releases an encoding crate against dusk-core 1.7.0. The patch is not
part of any crate version.

## PINNED-DIFFERENT-REDEPLOYED

Some releases change **bytecode or on-wire layout** (rkyv `repr(C)` pins,
call-type field layout, event payloads, authority rules). Those releases are
labeled **PINNED-DIFFERENT-REDEPLOYED** in `CHANGELOG.md`:

- **PINNED** — the layout is fixed intentionally (goldens, explicit constants).
- **DIFFERENT** — bytecode or byte layout changed versus the prior deploy.
- **REDEPLOYED** — operators must deploy new WASM under a new `ContractId`,
  and every consumer that baked the old id in via `ATLAS_PIN_HEX` must be
  rebuilt against the new one.

Atlas is never upgraded in place. A new deploy is a new trust anchor: confirm
the id in the public deployments record before pinning it.

## Changelog

`CHANGELOG.md` follows Keep a Changelog. Deploy ids are recorded per release so
a consumer can trace which Atlas it is pinned to.
