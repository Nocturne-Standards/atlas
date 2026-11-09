# Atlas

Atlas is a per-deployment service registry for native Dusk (Piecrust) contracts.
It stores named contract ids and one guardian. One Atlas per deployment. It is
never upgraded: consumer `*-data` contracts bake the Atlas `ContractId` at
build time (`ATLAS_PIN_HEX` → `build.rs` → `const ATLAS_ID_BYTES`).

**Status:** testnet only, and not audited yet. Testnet runs v0.4.1
`fd2b8594031d56ae584301976e26f7348aaaea3a9900d2967201789f1b4e4ce9`
(tx `743432a6ab77bc2b34246b7deea5b9326f1d77c2feb659e27485fe903573633c`, `wasm_sha256` `cf259587c7a7013516921a4e8c71ef7ce99bc835793b10daed0ba1c46667e6a7`).
Guardian is knot-warden 0.2.1
`9222e9995febf7fed02a0910a58f7c4190e0f388653ddc8b0d12bb4ef944f607`
(`wasm_sha256` `abf1a0d72ed8c294e5486183ed1e2768ce32adf8c0b39740d529f08a7476f10d`), timelock 30 blocks.
DuskEVM testnet (chain 745) runs EvmAtlas 0.4.1
`0x152a7238426B403057aB2c7F2Bbe0B52EF694D90` with EvmWarden 0.4.1
`0x83966e7E879B05f660fab01e09B911651Be4Ef1D` as its guardian. Both delays are
150 blocks (about 5 minutes at 2-second blocks); the warden's scheduler is the
deployer address.
Older versions are history; ids per version are in
[`CHANGELOG.md`](CHANGELOG.md); the public deployments record is
[Nocturne-Standards/nocturne-deployments](https://github.com/Nocturne-Standards/nocturne-deployments)
(`contracts.atlas`, plus product instances such as `prediction-market-atlas`,
which stay on their own pinned version until their operator re-pins).

Architecture: [docs.nocturne-standards.org — Atlas](https://docs.nocturne-standards.org/v1/atlas/).

## Stack

| Piece | Role | Repo |
|---|---|---|
| **atlas** | Discovery: `resolve(name) -> Option<ContractId>`. One guardian (`Account`) | this repository |
| **knot** | M-of-N registry and proposals `call_raw`. Warden (`knot-warden` 0.2.1, testnet `9222e9995febf7fed02a0910a58f7c4190e0f388653ddc8b0d12bb4ef944f607`; knot `docs/warden.md`) is the delaying guardian in front of Atlas. Knot needs Atlas: its books accept writes only from the logic contract Atlas resolves, and the Atlas id is baked in at build time (`ATLAS_PIN_HEX`) | [Nocturne-Standards/knot](https://github.com/Nocturne-Standards/knot) |
| **EvmAtlas** | Same kernel on DuskEVM, with EvmWarden as the delaying guardian. Locators instead of `ContractId`. Deployed on DuskEVM testnet (chain 745) | [`evm/README.md`](evm/README.md) |

## Surface

| Method | Authority |
|---|---|
| `init_guardian` | deploy owner, direct call, once. Sets guardian and the initial delay. Rejects a delay above 777,600 blocks and a zero `Account::Contract` id |
| `set_service` | guardian, immediate. Rejects an empty or over-64-byte name, a zero id, and an id already stored under that name |
| `set_guardian`, `set_timelock` | guardian, timelocked (`schedule`). `set_guardian` rejects an account that cannot act (zero or genesis-style contract id, Atlas's own id, an invalid key) and an unchanged guardian; `set_timelock` rejects a delay above 777,600 blocks and an unchanged one |
| `accept_guardian` | the incoming guardian of a pending guardian change (a direct call from the key, or `caller` equal to the contract id). Emits `guardian_accepted` from 0.5.0 |
| `cancel_pending` | guardian, immediate |
| `execute_pending` | permissionless after `execute_at`; a guardian change also needs `accept_guardian` |
| `resolve`, `guardian`, `timelock_blocks`, `pending`, `pending_accepted` | permissionless reads |

## Guardian and timelock

`Account::External(pk)` — direct account call and `public_sender == pk`. A direct account call has an empty call stack below Atlas (a bare session), or exactly one frame, the genesis transfer contract (every Moonlight transaction enters through `spend_and_execute`). From 0.5.0 the depth is checked too, so a contract relaying through the transfer contract's `contract_to_contract` is refused; 0.4.1 checks only `caller` ([`docs/security-model.md`](docs/security-model.md)).
`Account::Contract(id)` — `caller == id`. Atlas does not call the guardian.
Warden is the contract for that slot when a service repoint must
wait (knot `docs/warden.md`). Knot-proposals `call_raw`s warden; warden calls
Atlas. Quorum stays in knot. Pointing the guardian straight at the proposals
contract also works, and then `set_service` lands in the `finalize`
transaction.

How long each change waits:

| Change | Plain guardian (key or contract) | knot-warden 0.2.1 as guardian (testnet) |
|---|---|---|
| Repoint a service (`set_service`) | immediate | warden `delay_blocks`, then Atlas applies it at once |
| Replace the guardian (`set_guardian`) | Atlas `timelock_blocks`, plus `accept_guardian` by the incoming guardian | warden `delay_blocks`, then Atlas `timelock_blocks`, plus `accept_guardian` |
| Change the delay (`set_timelock`) | Atlas `timelock_blocks` | the warden forwards it at once; Atlas waits `timelock_blocks` |

On testnet both delays are 30 blocks, so a repoint waits about 5 minutes and a
guardian change about 10.

`set_guardian` and `set_timelock` share one pending slot. `set_service` does
not wait and does not use the slot. A delay change at delay `0` applies in the
same call and still emits `pending_scheduled`, then the applied event. A
guardian change never does: the incoming guardian must call `accept_guardian`
(it applies in that call if the delay has passed), so a mistyped address, or a
contract that never calls Atlas, can never take the slot. The current guardian
stays in force and cancels a change that is never accepted. Raising or lowering
the delay waits out the current value. `init_guardian` is the only immediate
write of the delay. The method is not named `init`: Piecrust reserves that
export for the deploy constructor and rejects later calls.
`execute_pending` is permissionless after `execute_at`.
`cancel_pending` uses the current guardian. There is no remove for a service
name — repoint it.

Warden enforces its own delay on `set_service` before it calls Atlas. Atlas's
delay then only covers replacing the guardian. Pass that delay to
`init_guardian`. Leaving it at `0` makes the first rotation instant.

## Events

Payload types live in `atlas_encoding::events` and are decodable via the
data-driver `decode_event`.

| Topic | Payload | Emitted by |
|---|---|---|
| `guardian_set` | `GuardianSet` | `init_guardian`, `execute_pending(Guardian)` and `accept_guardian` once the delay has passed |
| `guardian_accepted` | `GuardianAccepted` | `accept_guardian` (0.5.0 and later; names the accepting account and `execute_at`) |
| `service_updated` | `ServiceUpdated` | `set_service` |
| `timelock_set` | `TimelockSet` | `init_guardian`, `execute_pending(Timelock)` (including the zero-delay path) |
| `pending_scheduled` | `PendingScheduled` | `schedule` (including the zero-delay path) |
| `pending_cancelled` | `PendingCancelled` | `cancel_pending` (0.6.0 and later the payload includes `execute_at`; earlier records carry the change only) |

## Consumer how-to

Full guide, with a tested `build.rs` and the checks to run before trusting an
id: [`docs/consumers.md`](docs/consumers.md). In short: pin `atlas-encoding` by
full commit (`rev`), not by tag (tags are unsigned and movable), and check the
`dusk-core` version that commit needs. crates.io is not yet published.

```toml
atlas-encoding = { git = "https://github.com/Nocturne-Standards/atlas", rev = "<40-hex commit>", package = "nocturne-atlas-encoding" }
```

Bake the Atlas id at build time: set `ATLAS_PIN_HEX` for a `build.rs` that
writes `const ATLAS_ID_BYTES`. Before pinning an id, check it against the
deployments record and read `guardian()`, `timelock_blocks()` and the warden's
`atlas()` on it. Read `resolve(name)` at runtime; do not hardcode
downstream logic ids. v0.2.0 consumers that called `constant`, `role`,
`gov_mode`, or `proposals` have to stop. Those reads are gone.

## Build / test

Toolchain **1.94.0** is a wire-format pin (layout goldens). Do not bump it
without re-running goldens.

```bash
make test     # atlas.wasm, atlas_test_proxy.wasm, knot WASM at Cargo.lock rev, then cargo test --workspace --release
make clippy
make fmt
make evm-test # Foundry. Needs git submodule update --init for forge-std.
make evm-fmt  # forge fmt --check for evm/
make evm-script-test # stubbed evm/script/deploy.sh resume paths
```

`make knot-wasm` clones [Nocturne-Standards/knot](https://github.com/Nocturne-Standards/knot)
at the `Cargo.lock`-pinned rev and builds `knot_registry.wasm`, `knot_proposals.wasm` and their data contracts
(needs network on a cold `target/knot-src`).

## Versioning

The tree is `atlas` 0.6.0, `atlas-encoding` 0.5.0, and
`atlas-event-decoder` 0.3.0 (host library that decodes event payloads to
JSON for the 0.3.1 to 0.6.0 records; `pending_cancelled` grows `execute_at`
at 0.6.0). `atlas-test-proxy` 0.3.0
(test-only, never deployed). The packages are named `nocturne-atlas-*`;
the Rust paths and WASM file names keep the short names. Per-crate semver, git tag-or-rev pins, and
PINNED-DIFFERENT-REDEPLOYED: [`docs/versioning.md`](docs/versioning.md).
Rationale: [`docs/design-notes.md`](docs/design-notes.md). Trust model:
[`docs/security-model.md`](docs/security-model.md).

## License

Apache-2.0 (`LICENSE`). Copyright 2026 Nocturne Standards contributors
(`NOTICE`).
