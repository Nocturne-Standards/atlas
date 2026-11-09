# EvmAtlas

Per-chain directory for DuskEVM. One deployment per chain id. First target is
chain 745. Deployed on DuskEVM testnet on 2026-10-28 (redeployed from
`b22f6e7`; the first pair from 2026-10-20 is history): EvmAtlas 0.4.1
`0x152a7238426B403057aB2c7F2Bbe0B52EF694D90` and EvmWarden 0.4.1
`0x83966e7E879B05f660fab01e09B911651Be4Ef1D`. The warden is the directory's
guardian, its scheduler is the deployer address, and both delays are 150
blocks. Testnet only, not audited yet.

Native Atlas is unchanged. Piecrust books keep calling native `resolve`. This
contract is not a mirror of that map. It stores locators.

## Locator

| Kind | Value | `data` |
|---|---|---|
| `KIND_EVM_ADDRESS` | 1 | address in the low 20 bytes, high 12 bytes zero, not `address(0)` |
| `KIND_NATIVE_ID` | 2 | full 32-byte Piecrust id, not zero |

`resolve` returns the stored pair. A missing name returns kind 0 and data 0.
`resolveAddress` and `resolveNativeId` revert `NotFound` or `KindMismatch`.
`unaliasedSender` loads a native id and returns the last 20 bytes of
`keccak256` of the raw 32-byte id. That is the unaliased cross-domain sender,
and it is the mapping Dusk's SDK uses (`duskContractIdToEvmAddress` in
`dusk-network/duskevm-sdk`). Compare it with `xDomainMessageSender()` on a
cross-domain message; `msg.sender` there is the `L2CrossDomainMessenger`.
The view recomputes it. The directory does not store a second address.

A name is a `bytes32`, raw UTF-8, left-aligned, zero-padded. Empty is
rejected (`EmptyName`); `deploy.sh` accepts 1 to 32 bytes. There is no `keccak`. The prefix (`evm.sound.`, `evm.duskevm.`,
`native.`) is a convention. The kind field is the check. There is no delete.
A repoint may change kind.

## Authority

The guardian is one `address`. `msg.sender == guardian` is the check. The
contract never calls its guardian.

| Method | Authority | Timing |
|---|---|---|
| `initGuardian` | deploy owner (`immutable` deployer). Rejects `address(0)` | once, immediate |
| `setService` | guardian, checked before the locator. Reverts `Unchanged` when kind and data already match | immediate |
| `setGuardian`, `setTimelock` | guardian. `setGuardian` rejects `address(0)`, a precompile address, and the directory itself | one shared slot |
| `acceptGuardian` | the incoming guardian of the pending guardian change (`GuardianAccepted`) | applies the change if `executeAt` has passed |
| `cancelPending` | guardian | immediate |
| `executePending` | anyone | after `executeAt` |

`executeAt = block.number + timelockBlocks`. `executePending` clears the slot
before it applies. Delay 0 emits `PendingScheduled` and applies a delay change
in the same transaction. A guardian change never applies at once: the incoming
guardian must `acceptGuardian` first (`executePending` reverts `NotAccepted`), so
a mistyped address can never take the slot and the current guardian cancels a
change that is never accepted. Raising and lowering the delay both wait out the current value.

`MAX_TIMELOCK_BLOCKS` is 3,888,000 (90 days at about 2 seconds per block).
`initGuardian` and `setTimelock` revert `TimelockTooLong` above it.

The constructor stores `chainId` and reverts `WrongChain` when
`block.chainid` does not match. A bytecode replay on another chain fails
closed.

## EvmWarden

Delaying guardian. Deploy the directory first, then the warden, then
`initGuardian(warden, timelock)`. The constructor takes
`(expectedChainId, atlas, scheduler, delayBlocks)`. `chainId` and `atlas`
are immutable. It reverts on the wrong chain, an account with no code, a
directory whose `chainId()` is not this chain, a zero scheduler, or a delay
above the cap.

| Call | Wait |
|---|---|
| `scheduleService` | `delayBlocks`, then the directory `setService` |
| `setDelay` | `delayBlocks`. While the warden is the directory guardian, reverts `DelayAboveTimelock` above the directory timelock (or a lower pending one) |
| `setScheduler` | `delayBlocks`, then the incoming scheduler must `acceptScheduler` (`SchedulerAccepted`); `executeAdmin` reverts `NotAccepted` until it has, even at delay 0 |
| `acceptAtlasGuardian` | scheduler only; the warden calls the directory's `acceptGuardian` when it is the incoming guardian of a directory change |
| `setGuardian` | `delayBlocks` here, then the directory timelock. Reverts `NotDirectoryGuardian` if the warden is not the directory guardian, `DirectoryChangePending` if the directory has a pending change |
| `setTimelock`, `cancelAtlasPending` | forwarded immediately. `setTimelock` reverts `GuardianChangeQueued` while a directory guardian change is queued, and `TimelockBelowDelay` below the warden delay (or a queued delay raise) |
| `cancelService`, `cancelAdmin` | immediate, scheduler only |
| `executeService`, `executeAdmin` | anyone, after `executeAt` |

A repoint waits at least the warden delay. A guardian change waits the warden
delay plus the directory timelock. The warden keeps the directory timelock at
or above its own delay (`T >= D`); to raise both, raise the timelock first.
`deploy.sh` checks the first pair. The 0.4.1 pair on testnet predates the
warden-side check. Admin kind 3 is `ADMIN_ATLAS_GUARDIAN`; `executeAdmin` emits
`AtlasGuardianForwarded` before it calls the directory `setGuardian`.

Testnet delay that matches about 5 minutes on DuskEVM: 150 blocks for both
the warden delay and the directory timelock. The 0.4.1 release uses these
low values; mainnet delays are a separate decision.

## Scripts

`script/deploy.sh` deploys the directory, deploys the warden, checks the
warden (code, `atlas()`, `chainId()`, `scheduler()`, `delayBlocks()`), calls
`initGuardian`, writes the cache, then schedules each manifest row that
`resolve` does not already match. A matching row is recorded and is not scheduled again.
A row already pending with the same locator is not scheduled again;
it is executed only after `delayBlocks`. If any row is still waiting,
the script exits 1 and the cache does not list that row.
Re-run with `ATLAS_ADDRESS` set to the directory after the delay. If
`initGuardian` never landed, also set `ATLAS_WARDEN`; the script checks that
warden against this run's values before it sends `initGuardian`, which has no
acceptance step and cannot be undone.

Required env: `ATLAS_RPC_URL`, `ATLAS_SCHEDULER`, `ATLAS_WARDEN_DELAY`,
`ATLAS_TIMELOCK_BLOCKS` (above 0, at most 3,888,000, not below the warden
delay), `ATLAS_MANIFEST`, and a keystore or account (`PRIVATE_KEY` is ignored).
`ATLAS_CHAIN_ID` defaults to 745. The cache defaults to `evm/deployments/cache.json`.
A scheduler that is not the deployer needs `ATLAS_SCHEDULER_UNLOCKED`,
`ATLAS_SCHEDULER_KEYSTORE`, or `ATLAS_SCHEDULER_ACCOUNT`.

`script/drift.sh` (read-only; `ATLAS_RPC_URL`, `ATLAS_EXPORT`) compares the
cache to the directory. With `DUSK_ATLAS_ID` set it also compares kind 2 rows to
native `resolve` (needs `cargo` and `curl`). `script/chain-check.sh` (read-only; `ATLAS_RPC_URL`) checks the RPC chain id, measures
the block time that every delay is counted in, and reports which opcodes the
chain accepts, by simulating contract creations with `eth_call`. Run it against
the target network before deploying. `script/diff-pin.sh` (read-only;
`ATLAS_RPC_URL`, `ATLAS_ADDRESS`, `ATLAS_PIN`) compares a lending pin to the
directory. `script/manifest.example.json` uses fake values. Replace them before
broadcast.

Needs Foundry, `jq`, and `python3`. `git submodule update --init` for
`forge-std`.

```bash
make evm-test
make evm-fmt
make evm-script-test # stubbed deploy.sh resume paths
```
