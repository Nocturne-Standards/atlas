# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### atlas 0.6.0 / atlas-encoding 0.5.0 / atlas-event-decoder 0.3.1

- `atlas-event-decoder` 0.3.1 adds a README and `readme` metadata to the crate. No code change from 0.3.0, which is on crates.io without a README.

- `pending_cancelled` carries `execute_at`, the height the withdrawn change would have applied at. The 0.4.0 encoding payload was the change only. The decoder keeps that older layout for records before 0.6.0.
- `set_service` panics `service unchanged` when the name already stores that id, and does not emit. A different id under the same name still updates.
- EvmAtlas `setService` reverts `Unchanged` when the name already stores that kind and data, and does not emit `ServiceSet`. A different kind or different data under the same name still updates.
- EvmAtlas `GuardianAccepted` carries `executeAt`, matching native `guardian_accepted`.
- The security model states the current source: one guardian slot, and `T >= D` enforced by the warden (EvmWarden and knot-warden), not by Atlas.

Two groups. The first is the next contract version (`atlas` 0.5.0,
`atlas-encoding` 0.4.0, `atlas-event-decoder` 0.2.0, `atlas-test-proxy`
0.3.0): new bytecode, not deployed, so it is **PINNED-DIFFERENT-REDEPLOYED**
once deployed under a new id. The second group is not tagged yet either, but
the 0.4.1 testnet deployments were built from commits that already include it.

### Next version: changed (native)

- An `Account::External` guardian, incoming guardian or deploy owner is accepted only on a direct call: the call stack below Atlas is empty (a bare session) or exactly the genesis transfer contract (a Moonlight transaction). Until now `caller == transfer contract` was enough, and the transfer contract's `contract_to_contract` lets any contract make the transfer contract call Atlas inside a transaction the key signed, with `public_sender` still the key. That reached the argument-free calls (`cancel_pending`, `accept_guardian`) and, blocked only by the timelock cap, `set_timelock`. The stack in that case is transfer → contract → transfer, so the depth check refuses it. Applies to every `External`-authorised entry point: guardian methods, `accept_guardian`, and `init_guardian`. `Account::Contract` is unchanged (`caller == id` at any depth). One extra host query per authenticated call.
- `cancel_pending`'s doc comment now says what the code does: cancel is allowed at any time, also after `execute_at`, until the change is applied; at `execute_at` cancel and execute race and transaction order decides.

### Next version: added (native)

- `accept_guardian` emits `guardian_accepted` with `GuardianAccepted { guardian, execute_at }`: the account that accepted, and the height from which the change can apply. `guardian_set` follows when the change applies (in the same call if the delay has passed). `pending_accepted()` no longer has to be polled. New type in `atlas-encoding` 0.4.0 with layout goldens; the existing payloads are unchanged.
- `atlas-event-decoder` 0.2.0 decodes `guardian_accepted` for records from 0.5.0 on (`GUARDIAN_ACCEPTED_SINCE`); for older records the topic is unknown. `DEPLOYMENT_VERSION` is now 0.4.1, the current record.
- `atlas-test-proxy` 0.3.0: `relay(target, fn_name, data)` forwards raw call bytes, so the VM tests rebuild the `contract_to_contract` call stack with the proxy at the transfer contract id. Tests: a relayed `cancel_pending`, `set_service`, `set_timelock`, `accept_guardian` and `init_guardian` are refused for keys; the same calls through one transfer-contract frame work; a contract guardian works through the transfer contract. Its README says never to deploy it.

### Next version: changed (DuskEVM)

- EvmWarden keeps the directory timelock at or above its own delay (`T >= D`), from both sides: `setTimelock` reverts `TimelockBelowDelay` below the warden delay or a delay raise queued in the warden, and, while the warden is the directory's guardian, `setDelay` reverts `DelayAboveTimelock` above the directory timelock or a lower timelock the directory has pending. Raising both now means raising the timelock first. `IEvmAtlas` gains `timelockBlocks()`. Why here and not in the directory: the two values live in two contracts that change independently, and the warden is the one place that sees both and writes the directory's timelock. A check in EvmAtlas or native Atlas would have to call the guardian, which the directory never does, and could not stop the guardian's own delay from rising later. The first pair is still the deploy's job: `deploy.sh` refuses `ATLAS_TIMELOCK_BLOCKS < ATLAS_WARDEN_DELAY` and checks both values on chain. On native, Atlas cannot see a warden's delay; until knot-warden refuses the same, `T >= D` there is a deploy-time setting (see `docs/security-model.md`).
- `evm/script/deploy.sh` checks the warden before every `initGuardian` (code present, `atlas()`, `chainId()`, `scheduler()`, `delayBlocks()` match this run), on resume and on a fresh deploy. `initGuardian` has no acceptance step, so a mistyped `ATLAS_WARDEN` on resume used to become the directory's guardian for good before `verify_pair` noticed. `deploy_resume_test.sh` covers each mismatch.

### Next version: documentation

- `docs/security-model.md`, `docs/design-notes.md`, `docs/consumers.md`, README: the direct-call rule now names the call-stack test, and what 0.4.1 still allows through `contract_to_contract` (`cancel_pending`, `accept_guardian`, and `set_timelock` stopped only by the cap); `T >= D` is described as a deploy-time setting on native and as enforced by the EvmWarden in this tree; cancel after `execute_at` and its race with execute; the deploy owner must be the BLS key that calls `init_guardian`; `guardian_accepted` in the event tables.
- `evm/README.md` gives the 2026-10-28 redeploy date for the current pair. The 0.4.1 entries below say which WASM size is the deployed artifact, and the 0.3.1 entry says the later warden id in the deployments record is wrong.

### Next version: repository

- `tools/atlas-js`: a read-only JS reader for Atlas (`resolve`, `guardian`, `timelock_blocks`, `pending`, `pending_accepted`) and a `callFacts` example for wallet activity. Its tests read `crates/atlas-encoding/tests/layout_goldens.rs` and fail when the JS layouts drift; a `js` CI job runs them. Checked live against the 0.4.1 testnet deployment; the read layouts have not changed since 0.3.1, so 0.6.0 is covered by the goldens. Not part of the Rust workspace.
- `scripts/check-public-surface.sh` and a `kit-gates` workflow: a leak gate over the tracked tree (credentials, private key blocks, local paths, private names and paths, unresolved markers). `.nocturne-public` marks the repository as public-tier. `.public-surface-allowlist` drops stale entries.
- `.gitignore` covers local agent and editor state and `.env*`. `CODEOWNERS` names `@ichbindas`.
- Every crate is `publish = false` until the crates.io step; `RELEASE-PENDING.md` lists each crate with a publish recommendation and the order (`atlas-encoding` first).
- Packages renamed to `nocturne-atlas-encoding`, `nocturne-atlas-event-decoder`, `nocturne-atlas` and `nocturne-atlas-test-proxy` (the crates.io pattern Knot uses). `[lib] name` keeps the Rust paths (`atlas_encoding`, ...) and the WASM file names (`atlas.wasm`, `atlas_test_proxy.wasm`); the crate Makefiles take the WASM name from the lib target. Consumers write `atlas-encoding = { package = "nocturne-atlas-encoding", ... }`; cargo `-p` flags use the new names. The package name feeds Cargo's symbol hashing, so the release WASM differs from a build of the previous commit; 0.5.0 is not deployed, so no recorded hash changes.

### Already in the 0.4.1 deployments: added

- `atlas-event-decoder` 0.1.0 (`publish = false`): `decode(contract, topic, version, bytes)` turns the five Atlas event payloads into JSON. Dispatch is the deployments key plus topic; the version comes from the deployment record, not the bytes. Supports the 0.3.1, 0.4.0, and 0.4.1 records, which share the `atlas-encoding` 0.3.0 event layout.

### Already in the 0.4.1 deployments: changed

- Deploy builds: `make release-wasm` does a clean build with `wasm-opt` required at binaryen version 116 and prints the `sha256`; the `crates/atlas` Makefile fails under `REQUIRE_WASM_OPT=1` when `wasm-opt` is missing or the wrong version, and a plain `make wasm` without it now warns not to deploy. CI has a `release-wasm` job (pinned, checksummed binaryen) that prints the hash in the job summary and uploads the WASM as the `atlas-wasm` artifact. The contract build remaps Cargo home, the sysroot, and the workspace root, and `scripts/release-wasm-docker.sh` reproduces the CI build on a Mac; Linux builds match across environments, macOS builds do not (function order), so the deploy artifact is the Linux one.
- Two-step guardian handover (native and EVM). `set_guardian` / `setGuardian` still schedules; the incoming guardian must then call `accept_guardian` / `acceptGuardian` (authenticated like a guardian call), and `execute_pending` / `executePending` refuses a guardian change that has not been accepted. A mistyped address, or a contract that never calls Atlas, can never take the slot, and the current guardian cancels the stuck change. Acceptance applies the change at once if the delay has passed, so a delay-zero rotation is schedule then accept; a delay change is unaffected. New read-only `pending_accepted()` / `pendingAccepted`. EvmWarden's `setScheduler` gets the same step (`acceptScheduler`), and `acceptAtlasGuardian` lets the warden accept as an incoming guardian. No native event type was added, so `atlas-encoding` keeps its layout and version.
- `rkyv` 0.7.46 (was 0.7.39) in every crate, fixing RUSTSEC-2026-0001. The layout goldens, contract, e2e and decoder tests pass unchanged. The `knot-encoding` dev-dependency moves to `67715cf` (knot v0.2.0 plus only the rkyv bump); `.cargo/audit.toml` keeps only RUSTSEC-2026-0235.
- `deny.toml` and a `deny` CI job (licences, sources, advisories); `make deny`.
- `init_guardian` and `set_guardian` also reject a reserved contract id (`[n, 0, ..., 0]`, which includes the transfer contract, the `caller` of every Moonlight transaction, so as guardian it made every account the guardian), Atlas's own id, and an `External` key whose bytes are not a valid curve point (`guardian contract id reserved`, `guardian cannot be atlas itself`, `guardian key invalid`). The archived key type does not check the curve, so Atlas does. The WASM grew to 105,516 bytes in a local build at that commit; the deployed 0.4.1 artifact (CI, Linux) is 107,009 bytes, see 0.4.1 Deploy.
- EvmAtlas and EvmWarden: new `AccountLib` rejects zero, precompile-range addresses (below `0x100`), the contract itself and the directory as guardian or scheduler (`ReservedAddress`); the warden refuses what the directory would. `scheduleService` requires the warden to be the directory guardian (`NotDirectoryGuardian`), so no repoint is queued that could never execute after a handover. `foundry.toml` pins `evm_version = "paris"` (no `PUSH0`), `bytecode_hash = "none"`, `cbor_metadata = false`.
- `evm/script/deploy.sh`: prints the warden address before `initGuardian`; on resume finishes a failed `initGuardian` (`ATLAS_WARDEN`, deployer only); verifies chain id, guardian, `warden.atlas()`, scheduler, delay and timelock before caching; atomic cache that an aborted run no longer replaces; service names validated and duplicates rejected; refuses a dirty tree for real signers and prints the commit. `drift.sh` fails on a wrong chain, an empty cache, a guardian that is not the cached warden, and any pending change.
- DuskEVM checked against the testnet RPC (chain 745, 2026-10-20): exactly 2.000 s blocks, opcodes through Cancun accepted (Osaka `CLZ` refused), and `unaliasedSender` equals Dusk's SDK mapping (`duskContractIdToEvmAddress`). New read-only `evm/script/chain-check.sh` repeats the chain id, block-time and opcode checks. The build stays on `paris`.
- Release build: `cargo build --locked`; `make release-wasm` requires rustc 1.94.0 and ignores `RUSTFLAGS`, `CARGO_ENCODED_RUSTFLAGS` and `CARGO_PROFILE_*`; the CI job runs the VM tests against the optimised artifact, fails when the build fails (pipefail), and uploads `SHA256SUMS` and `BUILD.txt` with the WASM; `release-wasm-docker.sh` pins its image by digest and re-hashes on the host. A weekly `cargo audit` workflow.
- EvmWarden: `setGuardian` reverts `NotDirectoryGuardian` when the warden is not the directory guardian and `DirectoryChangePending` when the directory holds a pending change; `setTimelock` reverts `GuardianChangeQueued` while a directory guardian change is queued. The forward in `executeAdmin` can no longer revert and leave the single admin slot occupied. `IEvmAtlas` gains `pending()`.

## [0.4.1] — 2026-10-20 · PINNED-DIFFERENT-REDEPLOYED

### Changed

- `dusk-core` and `dusk-vm` 1.7.0 (uplink 0.21). Contract bytecode differs from 0.4.0, so this is a redeploy under a new `ContractId`. Call types, events, and `atlas-encoding` 0.3.0 are unchanged. Deployed to testnet under a new id (see Deploy).
- `set_service` rejects an all-zero service id (`service id zero`). `init_guardian` and `set_guardian` reject `Account::Contract` with the zero id (`guardian contract id zero`). EvmAtlas already rejects the equivalent zero locator and zero guardian.
- EvmWarden emits `AtlasGuardianForwarded` when `executeAdmin` forwards a queued directory guardian change. EvmAtlas takes its kind constants from `LocatorLib`.
- Workspace `[profile.release]` is `opt-level = "z"`, LTO, one codegen unit. dusk-core 1.7.0 grew the WASM from 106,957 to 141,125 bytes at opt-level 3. The new profile gave 101,381 bytes for the code at that point. Later checks grew it; the deployed artifact is the 107,009-byte one in Deploy below.
- `dusk-bls12_381` is an optional dependency of `atlas`, enabled by the `data-driver` feature only. `atlas-test-proxy` drops unused `rkyv` and `bytecheck` dependencies.

### Fixed

- Test sessions set `BLOCK_HEIGHT` as a `u64`. `VM::genesis_session` stores an untyped 0 (4 bytes), which uplink 0.21 rejects. Test-only.
- `make clippy` builds the knot WASM first, so a clean checkout passes.

### Added

- `.cargo/audit.toml` records two accepted `rkyv` 0.7 advisories (RUSTSEC-2026-0001, RUSTSEC-2026-0235; `Rc`/`Arc` archives, unused here). CI runs `cargo audit`.
- `make evm-script-test` runs `evm/script/deploy_resume_test.sh` and `evm/script/drift_test.sh`; CI runs it in the `evm` job.
- `docs/consumers.md`: a tested `build.rs` for `ATLAS_PIN_HEX`, the checks to run before pinning an id, and pinning `atlas-encoding` by commit.

### Deploy

- Testnet Atlas `fd2b8594031d56ae584301976e26f7348aaaea3a9900d2967201789f1b4e4ce9`
  (tx `743432a6ab77bc2b34246b7deea5b9326f1d77c2feb659e27485fe903573633c`, `wasm_sha256` `cf259587c7a7013516921a4e8c71ef7ce99bc835793b10daed0ba1c46667e6a7`, 107,009 bytes, the CI `atlas-wasm` artifact).
- Testnet knot-warden 0.2.1 `9222e9995febf7fed02a0910a58f7c4190e0f388653ddc8b0d12bb4ef944f607`
  (tx `7944e22f4247ee8c1f51af9cc08c65db70d05fc2880dfb5cc6ce837b3c3dcb1f`, `wasm_sha256` `abf1a0d72ed8c294e5486183ed1e2768ce32adf8c0b39740d529f08a7476f10d`, 177,230 bytes, built in the pinned container from knot `1c82dd5`).
- `init_warden` (scheduler: the deployer, delay 30 blocks), then `init_guardian` naming the warden (timelock 30 blocks). Services, including `knot-registry`, were scheduled through the warden and executed after the delay; each reads back through `resolve`.
- First DuskEVM testnet pair (history) (chain 745), source commit `05ed94e`: EvmAtlas `0xEF81aA8101E89697Bd409beA186C7e0cD7Ebf1b6`, EvmWarden `0x2E0EA836cfebeFefe51A5C7f881B8BbE5De6f265` (guardian), delays 150/150 blocks, scheduler the deployer address. The `native.*` rows (the services above) resolve with kind 2.
- DuskEVM testnet (chain 745), redeployed 2026-10-28 from `b22f6e7` with a new scheduler: EvmAtlas `0x152a7238426B403057aB2c7F2Bbe0B52EF694D90`, EvmWarden `0x83966e7E879B05f660fab01e09B911651Be4Ef1D` (guardian), delays 150/150 blocks. The first pair stays on chain and is no longer the one we point to.

## [0.4.0] — 2026-10-18 · PINNED-DIFFERENT-REDEPLOYED

History. Superseded by 0.4.1; new pins use 0.4.1.

### Added

- DuskEVM directory `EvmAtlas`, delaying guardian `EvmWarden`, and `evm/script/deploy.sh`, `drift.sh`, `diff-pin.sh`. Not deployed. `resolve_arg` encodes and decodes native `resolve` arguments for the drift script.

### Changed

- `init_guardian` and `set_timelock` reject a delay above 777,600 blocks (`timelock above maximum`). `set_service` rejects an empty name and a name longer than 64 bytes. `atlas-encoding` stays 0.3.0.
- EvmWarden queues a directory guardian change for `delayBlocks` before `setGuardian`. The warden is configured in its constructor. `setService` checks the guardian before the locator. EvmAtlas and EvmWarden are not deployed.

### Deploy (history)

- Testnet id `27882147345ff547ef37fc4fbd5bf247d8c340950b8131f9e91e672d30239724`
  (tx `a8186cc6ed658c9ea41a393afc95d044acc5143274b7b029f1a474940f17474c`).
  `init_guardian` set knot-warden 0.2.0
  `7d1659d658a6a9b8781e8f85b3f7708a4e3079dd75b706ea855fbf0c6d2c7000`
  with `timelock_blocks` 30
  (tx `0ad4cbb54acf5e786c3e3416e5c71f02d8e29a44dd07ffb39ad8e5e21c04946d`).
  That warden's deploy tx is
  `73f8f0f17e329b685916ee52cee1596c68bbfa834613b0dc780ca52ab2e9a801`
  and its `init_warden` tx is
  `2c45aa380109fabafca8a51b0ea8c6b8f7617b37a942eb6113d6bafc1f90ac6b`
  (`delay_blocks` 30). Supersedes 0.3.1 for new pins. 0.3.1
  `21c653385e3b7cc8be32edd5e6df2e30b6464be867f39442171ba8ca8d089612`
  stays until a consumer re-pins.

## [0.3.1] — 2026-09-23

### Fixed

- A Moonlight transaction's `caller` is the genesis transfer contract
  (`spend_and_execute`), not unset. `init_guardian` and `Account::External`
  treat that caller as a direct account call, together with a bare session
  call. Any other caller still panics. Encoding layout is unchanged
  (`atlas-encoding` 0.3.0).

### Deploy

- Testnet id `21c653385e3b7cc8be32edd5e6df2e30b6464be867f39442171ba8ca8d089612`
  (tx `8a84c2ba63214747fd65eeef21c9e8d6cd28945e6ca53f1952484982c47d321e`).
  `init_guardian` set warden
  `fb143b1e10288ea6527edc2e556c009d78e7a01add076ab90d6e133aec47cdcb`
  with `timelock_blocks` 2
  (tx `67d6b00b1fab9cdf2a5b236caacf271b35e83713b6f4a0f374d814d829667a60`).
  Supersedes
  `38cf71e6e32d892319bf631eafef1a44fbf9f6b02e8dfe64177cf4d7dc2dce46`,
  which a wallet cannot initialize.
  The deployments record later names warden
  `113159d33377e7778d552cc48f40318c44643ca06970e2482b41b276a4d9cdb3`
  (0.1.1, deploy tx
  `ebf2d30d449860949d44aeb904b01188a90d3853a95e84ffc8a71bce88676d0a`,
  2026-09-27). That record has no `init_warden` for this id and no
  `set_guardian` that moved the guardian off the first warden, so that entry
  is wrong: `113159d3…` never became this instance's guardian. The record
  needs the same correction.

## [0.3.0] — 2026-09-23 · PINNED-DIFFERENT-REDEPLOYED

### Changed

- Guardian is one `Account`: `External(BlsPublicKey)` or `Contract(ContractId)`.
  `init_guardian(InitArgs)` replaces `init_operator`. Deploy owner, direct call,
  once. Sets the guardian and the initial delay. The method is not named
  `init` because Piecrust reserves that export for the deploy constructor.
- `set_service` is immediate. Only `set_guardian` and `set_timelock` wait, and
  they share one pending slot. An external guardian must be a direct call
  (`caller` is `None` and `public_sender` matches the key). A contract guardian
  matches `caller`. Atlas does not call out.
- `atlas-encoding` 0.3.0. Call-type and event layout changed. `SetServiceArgs`,
  `ServiceUpdated`, and `TimelockSet` bytes are unchanged. `Account` and
  `PendingChange` are golden-pinned enums.

### Removed

- Constants, roles, `GovMode`, the proposals id, and the methods that served
  them (`constant`, `role`, `gov_mode`, `proposals`, `set_constant`, `set_role`,
  `set_gov_mode`, `init_proposals`, `set_proposals`).

### Deploy

- Testnet id `38cf71e6e32d892319bf631eafef1a44fbf9f6b02e8dfe64177cf4d7dc2dce46`
  (tx `a66bf04b5d317e0b0b8a88066067942d88cd1f53c33b8adac2409229343b7046`).
  A wallet cannot initialize it: the direct-call check rejects the transfer
  contract caller. Superseded by 0.3.1. v0.2.0
  `48d998a29a8a7bd357f3913c89446d0956e6aaae9185d83a84fc2d07e9b27e09` stays
  live for consumers still pinned to it. Consumers re-pin `ATLAS_PIN_HEX` and `atlas-encoding` together.
  No `v0.3.0` tag: `crates/atlas` went from 0.2.0 to 0.3.1 in `a20ad3f`.
  The 0.3.0 bytecode is not its own commit on this branch.

## [0.2.0] — 2026-09-20 · PINNED-DIFFERENT-REDEPLOYED

### Security

- `init_proposals` is once-only; repointing goes through timelocked `set_proposals`.

### Added

- Typed event payloads (`atlas-encoding::events`) on every mutation; layout goldens.
- `atlas-encoding` crate (host-visible types), workspace split.
- `atlas-encoding` feature `contract-events` (off by default) carries the `ContractEvent` topic impls.

### Changed

- Dependencies: `dusk-core`/`dusk-vm` 1.6.0 from crates.io; knot dev-dep re-pinned to public repo.

### Deploy

- Bytecode changed; call-type layout unchanged. Consumers move `ATLAS_PIN_HEX` to the new id.
- Testnet, fresh canonical instance (key `atlas` in the public deployments record; product instances are re-pinned by their operators):
  `contract_id` `48d998a29a8a7bd357f3913c89446d0956e6aaae9185d83a84fc2d07e9b27e09`,
  deploy tx `71363d9d7cf5c5b2210d885ab4e01bc09410c0807f3f2a0fa1e763af96ce4049`,
  `wasm_sha256` `63889124267dddb8b8471e8dd4ab096bd38187409a08b9993bc87ac55068d333`,
  `init_operator` tx `7c8ac817adaca36894ada4ebc5843af1d8b79f18ec115e2eed709263386e8641` (Operator mode, deploy owner key).

## [0.1.1] — 2026-08-03 · PINNED-DIFFERENT-REDEPLOYED

- `#[archive_attr(repr(C))]` on struct Archive call types (`SetServiceArgs`, `SetRoleArgs`, `SetConstantArgs`, `PendingView`); enums `GovMode` / `PendingChange` golden-only pin. Measured DIFFERENT on `SetServiceArgs`.
- Redeployed to three testnet keys (shared wasm_sha256 `26076b566609c5e2e456f1e212dfe9b469c98a9a4a75a0920e0e1cea03fc48f6`): `atlas` `a7fd9146…`, `prediction-market-atlas` `490b5b2e…`, `nft-marketplace-atlas` `e0ae4246…`. Prior v0.1.0 wasm_sha256 `232b35f12b34d894b89f40d413848d03cba9d38cf266cc4d449760350ba69b9c`.

## [0.1.0] — 2026-07-23

- Initial testnet deploy (Operator, `init_proposals`, `"treasury"` → logic). Smoke: `set_constant("smoke_bps", 42)`.

<!-- No compare links: the public repository starts from a single commit and its
     first tag will be v0.5.0, so tags for the versions above do not exist there.
     On the v0.5.0 release, add: [0.5.0]: https://github.com/Nocturne-Standards/atlas/releases/tag/v0.5.0 -->
