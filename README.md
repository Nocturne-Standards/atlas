# Atlas

A per-deployment service registry for native [Dusk](https://dusk.network)
(Piecrust) contracts. Atlas maps names to contract ids and has one guardian
that may change them. Other contracts look a service up with
`resolve(name) -> Option<ContractId>` instead of hardcoding its id.

One Atlas per deployment, and it is never upgraded: consumer contracts bake
the Atlas `ContractId` in at build time. There is also **EvmAtlas**, the same
kernel for DuskEVM.

> **Testnet only. Not audited.** Do not put value behind it.

## Use it from Rust

Add the call types and event payloads:

```toml
atlas-encoding = { package = "nocturne-atlas-encoding", version = "0.5" }
```

Then:

1. Take the Atlas id from the public deployments record for the network you
   target. Do not copy it from a blog post or a chat.
2. Check it on chain: read `guardian()` and `timelock_blocks()` on that id, and
   `atlas()` on the warden.
3. Bake the id into your contract at build time. Set `ATLAS_PIN_HEX` (64 hex
   characters) and let a `build.rs` write it to a constant
   (`const ATLAS_ID_BYTES`).
4. Call `resolve(name)` at runtime. Do not hardcode the ids of downstream
   contracts.

A crate version is not a contract id: the id from step 1 is what you trust.
The full guide, with a tested `build.rs` and the checks to run before trusting
an id, is [`docs/consumers.md`](docs/consumers.md). Release history, with the
ids each version was deployed under, is in [`CHANGELOG.md`](CHANGELOG.md).

## What Atlas exposes

| Method | Who can call | When it applies |
|---|---|---|
| `init_guardian` | deploy owner, once | immediately; sets the guardian and the initial delay |
| `set_service` | guardian | immediately |
| `set_guardian`, `set_timelock` | guardian | after the timelock, queued as one pending change |
| `accept_guardian` | the incoming guardian | completes a pending guardian change |
| `cancel_pending` | guardian | immediately |
| `execute_pending` | anyone | after `execute_at` |
| `resolve`, `guardian`, `timelock_blocks`, `pending`, `pending_accepted` | anyone | read only |

Limits: names are 1 to 64 bytes, ids are non-zero, and `set_service` rejects
an id already stored under that name. Delays are capped at 777,600 blocks.
`set_guardian` rejects accounts that cannot act and an unchanged guardian. The
exact rules are in [`docs/security-model.md`](docs/security-model.md).

## Guardian and timelock

The guardian is an `Account`: either an external key (`Account::External(pk)`)
or a contract (`Account::Contract(id)`). Atlas never calls its guardian.

For a service change that has to wait, put a **warden** in the guardian slot.
knot-warden queues the change and applies it after the delay, so signers can
see and cancel it. Quorum stays in [knot](https://github.com/Nocturne-Standards/knot):
knot-proposals `call_raw`s the warden, and the warden calls Atlas. Pointing the
guardian straight at the proposals contract also works; then `set_service`
lands in the `finalize` transaction.

## Layout

| Path | What |
|---|---|
| `crates/atlas` | the contract (WASM) |
| `crates/atlas-encoding` | call types and event payloads, rkyv layout pinned by golden tests |
| `crates/atlas-event-decoder` | host library that decodes event payloads to JSON |
| `crates/atlas-test-proxy` | test fixture, never deployed |
| `evm/` | EvmAtlas and EvmWarden (Foundry). See [`evm/README.md`](evm/README.md) |
| `tools/atlas-js` | read-only JS reader |
| `docs/` | consumers guide, security model, versioning, design notes |

## Build and test

Toolchain **1.94.0** is a wire-format pin: do not bump it without re-running
the layout goldens.

```bash
make test        # atlas.wasm, test proxy, knot WASM, then cargo test --workspace --release
make clippy
make fmt
make evm-test    # Foundry; run `git submodule update --init` first for forge-std
make evm-fmt
```

`make knot-wasm` clones [Nocturne-Standards/knot](https://github.com/Nocturne-Standards/knot)
at the commit named by `KNOT_REV` in the `Makefile` and builds the registry, proposals and
data contracts for the end-to-end tests. It needs network on a cold
`target/knot-src`.

## Versions and docs

This tree is `atlas` 0.6.0, `atlas-encoding` 0.5.0 and `atlas-event-decoder`
0.3.1. Each crate has its own semver; a release that changes bytecode or wire
layout is marked `PINNED-DIFFERENT-REDEPLOYED` in the changelog, meaning it
needs a new contract id.

- [`docs/versioning.md`](docs/versioning.md): versioning rules
- [`docs/security-model.md`](docs/security-model.md): trust model
- [`docs/design-notes.md`](docs/design-notes.md): rationale
- [Atlas on docs.nocturne-standards.org](https://docs.nocturne-standards.org/v1/atlas/): architecture

## License

Apache-2.0 (see `LICENSE`). Copyright 2026 Nocturne Standards contributors.
