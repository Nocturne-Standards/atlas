# Contributing

Thanks for your interest in Atlas. This repo is **testnet software**, not audited
yet: a small registry contract, its host-visible types, and the DuskEVM
contracts in `evm/`.

## Before you start

1. Read [`docs/security-model.md`](docs/security-model.md) and
   [`docs/versioning.md`](docs/versioning.md).
2. Open an issue or draft PR describing the change — especially for anything
   that touches the contract ABI, a call-type or event-payload layout, or the
   authority rules. Those require a coordinated redeploy.

## Development setup

```bash
rustc --version   # 1.94.0 (rust-toolchain.toml installs it)
make test
```

`make test` builds `atlas.wasm` and `atlas_test_proxy.wasm`, then runs
`make knot-wasm`, which clones
[Nocturne-Standards/knot](https://github.com/Nocturne-Standards/knot) at the
rev pinned in `Cargo.lock` under `target/knot-src` and builds
`knot_registry.wasm`, `knot_proposals.wasm` and their two data contracts for the end-to-end test.
Deploy builds use `make release-wasm` (needs `wasm-opt` from binaryen version
116; prints the `wasm_sha256`) on Linux. On a Mac run
`scripts/release-wasm-docker.sh` (Docker, builds HEAD): a macOS build is not
byte-identical to the CI one. `make knot-wasm` needs network access on first run. `jq` is required by the
contract Makefiles. `cargo audit` needs `cargo-audit`
(`cargo install cargo-audit --locked --version 0.22.2`, the CI version); accepted advisories live in
`.cargo/audit.toml`.

EVM (`evm/`): Foundry (this repo's CI pins `v1.7.1`), `python3`, `jq`, and
`git submodule update --init` so `forge-std` is present. `rg` and `python3`
are also required by `scripts/check-bls-insecure.sh`.

```bash
git submodule update --init
make evm-test
```

Other targets: `make clippy`, `make fmt`, `make wasm`, `make evm-fmt`,
`make evm-script-test` (stubbed run of `evm/script/deploy.sh` resume paths),
`make clean`, `make help`.

## Layout goldens are a contract

`crates/atlas-encoding/tests/layout_goldens.rs` pins the rkyv archived bytes
of every call type and event payload. A failing golden is a **finding**, not a
test to update: it means the wire format moved. If the change is intended,
bump the crate version, add a `PINNED-DIFFERENT-REDEPLOYED` entry to
`CHANGELOG.md`, and regenerate the constants in the same PR with the reason
stated.

The toolchain pin (1.94.0) is part of that contract. Do not bump it without
re-running the goldens. The workspace `[profile.release]` (`opt-level = "z"`,
LTO, one codegen unit) is pinned for the same reason: changing it changes the
contract WASM and its deployed hash.

## Pull requests

- Keep diffs focused; separate mechanical refactors from behaviour changes.
- Run `cargo fmt --all --check`, `make clippy`, and `make test` before
  pushing. CI runs the same plus `scripts/check-bls-insecure.sh`, `cargo audit`,
and `make evm-script-test`.
- Update `CHANGELOG.md` when user-visible behaviour changes. ABI or
  event-payload changes need a `PINNED-DIFFERENT-REDEPLOYED` entry and a
  coordinated redeploy of Atlas and every consumer pinned to it.
- Every new exported `pub fn` on a contract state struct is a public WASM
  export: add a line to `.contract-authz-baseline` stating who may call it.
  Review checks this; CI does not.
- Do not commit secrets, `.env` files, or absolute local paths.
  `scripts/check-public-surface.sh` checks the tree for those and for other
  text that does not belong in a public repository; the `kit-gates` workflow
  runs it on every pull request.
- `*_insecure` BLS helpers are allowed only on the test paths listed in
  `scripts/bls-insecure-allowlist.txt`, each with a `PreforkHostQuery`
  justification comment. Production code uses `sign`, `verify`,
  `sign_multisig`, and `aggregate` only.

## Licensing

Contributions are accepted under Apache-2.0 (see `LICENSE`).
