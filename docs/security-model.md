# Security model

What Atlas trusts, what it checks itself, and what it leaves to the guardian.
Read this before pinning an Atlas id into a consumer contract.

## What Atlas is

A per-project registry: names to `ContractId`s, plus one guardian and the
delay on replacing that guardian. It holds no funds and verifies no
signatures. Consumers bake its id in at build time. The contracts behind the
names stay movable through `set_service`.

## Trust model

| State | Trusted party | Check performed by Atlas |
|---|---|---|
| Uninitialized | Deploy owner | Direct account call and `public_sender == self_owner()`, used **only** by `init_guardian` |
| `Account::External(pk)` | Holder of that BLS key | Direct account call and `public_sender == pk` |
| `Account::Contract(id)` | That contract | `caller == Some(id)`. `public_sender` is ignored |

A direct account call has an empty call stack below Atlas (a bare session
call) or exactly one frame, the genesis transfer contract: every Moonlight
transaction arrives through that contract's `spend_and_execute`. Any other
caller, or a deeper stack, is another contract using the key. The depth test is
new in 0.6.0; 0.4.1 and older check only that `caller` is the transfer
contract (see "A key that signs anything else" below).

Atlas does not call the guardian. A contract guardian is trusted entirely for
whatever policy it implements before it calls in: quorum, allowlists, its own
delay on `set_service`. If that contract is wrong, Atlas follows it.

The deploy owner has exactly one power: calling `init_guardian` once. After
that the owner key has no special standing. The method is not named `init`
because Piecrust reserves that export for the deploy constructor. Deploy with
the owner set to the BLS public key that will call `init_guardian`: Atlas reads
it with `self_owner()`, which panics when the owner bytes are not a valid key,
so an instance deployed with any other owner can never be initialised.

Until `execute_pending`, the previous guardian remains the only writer. The
scheduled account cannot `set_service`, cancel, or schedule something else.

## Authority matrix

| Method | Authority | Timing |
|---|---|---|
| `init_guardian` | Deploy owner | Immediate, once. Sets guardian and the initial delay |
| `set_service` | Guardian | Immediate |
| `set_guardian`, `set_timelock` | Guardian | Timelocked (`schedule`) |
| `accept_guardian` | Incoming guardian of a pending guardian change | Applies the change in that call once the delay has passed |
| `cancel_pending` | Guardian | Immediate |
| `execute_pending` | Anyone | After `execute_at` |
| `resolve`, `guardian`, `timelock_blocks`, `pending`, `pending_accepted` | Anyone | Read |

## Timelock

`set_guardian` and `set_timelock` store one `PendingChange` with
`execute_at = block_height() + timelock_blocks` and emit `pending_scheduled`.

- At most one pending change. A second `schedule` panics until the first is
  cancelled or executed.
- `execute_pending` panics before `execute_at`, then clears `pending` before
  applying. Anyone may call it.
- `cancel_pending` requires the current guardian. It works at any time until
  the change is applied, also after `execute_at`. At `execute_at` a cancel and
  a permissionless `execute_pending` race, and transaction order decides.
- `set_timelock` is itself timelocked. Lowering or raising the delay waits out
  the current delay. The value passed to `init_guardian` is the only immediate
  write.
- With delay `0`, a delay change emits `pending_scheduled` and applies in the
  same call. A guardian change does not: it waits for `accept_guardian`.
- A guardian change applies only when the delay has passed AND the incoming
  guardian has called `accept_guardian`, authenticated like a guardian call.
  `execute_pending` refuses an unaccepted one (`incoming guardian has not
  accepted`). Accepting after the delay applies the change in that call.
  Cancelling clears the acceptance. `pending_accepted()` is a read-only view.
- Scheduling the current guardian, or the current delay, panics and does not
  take the slot.
- `set_service` does not read or write `pending`.
- `init_guardian` and `set_timelock` reject a delay above 777,600 blocks
  (90 days at 10 seconds per block). The panic is `timelock above maximum`.
  The overflow check on `block_height + delay` stays as a second guard.
- A pending change has no expiry. Anyone may execute it at any height from
  `execute_at` on.
- `set_service` rejects an empty name and a name longer than 64 bytes. Names
  are case-sensitive bytes with no other rule, so lookalike names are the
  guardian's to avoid.
- `set_service` rejects an all-zero service id. `init_guardian` and
  `set_guardian` reject `Account::Contract` with the zero id, which could
  never match `caller`. 0.4.1 and later. A key guardian cannot be checked
  this way.
- `set_service` rejects an id already stored under that name
  (`service unchanged`) and does not emit. From 0.6.0. A different id under
  the same name still updates and emits `service_updated`.

### One guardian slot

Atlas stores one guardian. That account is either a key or a contract that
calls Atlas itself, or it is a warden. Those two are not stacked.

- Guardian calls Atlas. `set_service` is immediate. There is no warden delay.
- Scheduler calls the warden, the warden waits `delay_blocks`, then the warden
  calls Atlas. In that setup the warden contract is the guardian. The
  scheduler is not a second guardian in front of it.

A repoint through the warden waits `delay_blocks`, then Atlas applies it at
once. A guardian change waits `delay_blocks` in the warden, then the Atlas
timelock, and the incoming guardian must call `accept_guardian`.
`set_timelock` and `cancel_pending` are forwarded in the same transaction.
Atlas then waits its own timelock on a delay change. Cancel is immediate.
Lowering the directory delay grants no `set_service` power.

### Who enforces `T >= D`

The Atlas timelock `T` should be at least the warden delay `D`, so handing
the guardian slot to someone else does not become a shorter wait than a
repoint. Only the warden enforces that. It is the contract that can read
both numbers: its own `delay_blocks`, and Atlas `timelock_blocks`.

Atlas does not enforce it. Atlas never calls its guardian, so it cannot
read a warden delay, and a plain guardian has no delay to compare. A check
inside Atlas would have to call the guardian. The directory does not do that.

`EvmWarden` in this repo and `knot-warden` in the knot repo both refuse a
timelock below the warden delay and a delay raise above the directory
timelock. Raise the Atlas timelock first when both must go up. The first
pair is still chosen at `init_guardian`, `init_warden`, or `deploy.sh`,
because the warden is initialised before Atlas names it. How long the two
numbers are is a product choice, up to the directory cap (777,600 blocks
on native, 3,888,000 on DuskEVM).

### Threat model

A compromised external key, or a compromised guardian contract, can:

- repoint any service immediately (`set_service`);
- schedule a guardian replacement or a delay change, visible as
  `pending_scheduled`, which applies after `timelock_blocks`.

The delay is a reaction window on **who the guardian is**, not a veto. Cancel
needs the same guardian that scheduled. If that guardian is the attacker,
Atlas cannot stop the change. Observers use the window at the layer that
still has a lever: leave the service, pause a vault, rotate a committee
inside the guardian contract.

A guardian contract can add its own delay before it calls `set_service`.
Atlas will not.

A guardian change applies only after the incoming guardian calls
`accept_guardian`. A mistyped key, or a contract id that never calls Atlas,
never accepts, so it never takes the slot, and the current guardian cancels the
change.

Production `init_guardian` should pass a non-zero delay, or pass the long-term contract
guardian directly. An external key initialized at delay `0` can rotate in the
same transaction until a `set_timelock` has been executed.

## Events as the observation surface

`init_guardian` emits `guardian_set` and `timelock_set`. Other mutations emit the event
for the write they performed. A zero-delay schedule emits `pending_scheduled`
and then the applied event. From 0.6.0, `accept_guardian` emits
`guardian_accepted` with the accepting account and `execute_at`, followed by
`guardian_set` when the change applies in the same call; 0.4.1 emits nothing on
acceptance and `pending_accepted()` has to be read. Payloads carry the full new value. Monitoring
`pending_scheduled` is the alerting hook for guardian changes, and
`pending_cancelled` closes one. Without a warden, `service_updated` fires
only after the repoint has landed. With one, EvmWarden's `ServiceScheduled`
is the early signal. The tree's EvmWarden also emits `AtlasGuardianForwarded`
when a queued directory guardian change reaches the directory.

## What Atlas does not protect

- **Funds.** Atlas has none.
- **Service-level policy.** Fees, roles, and allowlists belong to the logic
  contract `resolve` returns, or to the guardian.
- **Quorum.** A contract guardian is trusted at `caller`. M-of-N, if any,
  happens inside that contract (knot, when knot is the guardian).
- **Stale reads.** A cached `resolve` result goes stale when `set_service`
  runs. Read through.
- **Deletion.** There is no remove for a service name. A retired name keeps
  its last id until repointed.
- **A wrong or stale pin.** A consumer trusts the instance it baked in. A
  redeploy is a new id; the old instance stays live under its old guardian.
  Read `guardian` and `timelock_blocks` on the pinned id before relying on it.
- **A guardian that cannot act.** Atlas rejects accounts that can never act:
  the zero id, genesis-style contract ids `[n, 0, ..., 0]` (the transfer
  contract is the `caller` of every Moonlight transaction, so naming it made
  every account the guardian), its own id, and an `External` key whose bytes are
  not a valid curve point. A valid key you mistyped, or a contract that never
  calls Atlas, passes those checks but can never call `accept_guardian`, so
  the change never applies and the current guardian cancels it. What remains is
  the first guardian, which `init_guardian` sets with no acceptance (the deploy
  owner chooses it): read it back after deploying. Acceptance proves the new
  account can act, not that it is the account you meant: a key that someone
  else controls and who accepts is a valid takeover, which is why the delay and
  `pending_scheduled` stay the window to react.
- **The delay is not a veto.** A compromised guardian, or a compromised warden
  scheduler, can schedule a repoint and a replacement of itself in the same
  window; the replacement lands one delay after the repoint is executable.
  Only the compromised party can cancel. Observers must act on
  `pending_scheduled` and the warden's `service_scheduled`.
- **A key that signs anything else.** The genesis transfer contract can call
  other contracts on behalf of a Moonlight sender (`contract_to_contract`),
  and `public_sender` stays the original signer for the whole transaction. At
  the callee, `caller` is the transfer contract, as on a direct call.
  - **0.6.0 and later:** an `External` account (guardian, incoming guardian,
    deploy owner) is accepted only when the call stack below Atlas is empty or
    is exactly the transfer contract. The relay path has three frames
    (transfer, the relaying contract, transfer) and is refused. Contract
    accounts are matched on `caller` and are not affected.
  - **0.4.1 and older (the deployed testnet instance):** only `caller` is
    checked, so a malicious contract that an `External` guardian key is
    tricked into calling can reach Atlas as that key. The arguments must
    still decode as the method's type, which leaves the calls that take no
    argument (`cancel_pending`, `accept_guardian`) and `set_timelock`, whose
    forged `u64` is always above 777,600 and is refused only by the timelock
    cap. `set_service` and `set_guardian` are out of practical reach.
  - knot-warden 0.2.1 uses the same caller-only test for its `External`
    scheduler (`cancel_admin`, `cancel_atlas_pending`, `accept_*`;
    `set_delay` and `set_timelock` are refused by the cap). On testnet its
    scheduler is a key.

  Keep guardian and scheduler keys dedicated to that role, or use a contract
  account.
- **An orphaned warden.** After Atlas applies a new guardian, the old
  warden's queued entries can never execute. They are inert, not cleared, and
  no event says the warden stopped being the guardian. Watch Atlas
  `guardian_set`.
- **Pending changes never expire.** A queued change can be executed by anyone
  at any later height, so a stale entry that was not cancelled lands when a
  bystander chooses. Cancel what you do not intend to apply.
- **Old bytecode.** Older instances keep the rules they were built with. The
  0.3.1 instance (history, still live until consumers re-pin) accepts an empty
  name, a name longer than 64 bytes, and a timelock above 777,600 blocks. The
  zero-id, reserved-id and key-validity checks, and `accept_guardian`, exist
  only from 0.4.1 on (deployed on testnet with knot-warden 0.2.1). The
  call-depth test for keys and the `guardian_accepted` event exist from
  0.6.0 on. `pending_cancelled` carries `execute_at`, and `set_service`
  rejects an unchanged id, from 0.6.0. Check which version you pin.

## DuskEVM

`evm/src/EvmAtlas.sol` is the same kernel on DuskEVM: one guardian, immediate
`setService`, one pending slot for `setGuardian` and `setTimelock`. It stores
a locator, not a Piecrust `ContractId`. Kind 1 is an EVM address. Kind 2 is a
32-byte native id. `unaliasedSender` is the last 20 bytes of `keccak256` of
that raw id. It holds no funds and it never calls its guardian.

Authority on EVM is `msg.sender == guardian` (EvmAtlas) or `== scheduler`
(EvmWarden), with no direct-call test, so an EOA or a contract both work.
`resolve` returns kind 0 for an unknown name; the typed reads revert
`NotFound`. `setService` checks the guardian first, then name, kind and
locator (zero name, zero locator, dirty address bits, bad kind revert).
EvmAtlas `setService` reverts `Unchanged` when the name already stores that
kind and data, and does not emit `ServiceSet`. Native `set_service` rejects
the same case from 0.6.0. EvmWarden `scheduleService` reverts `Unchanged`
before it queues. `GuardianAccepted` carries
`executeAt`, the same height native `guardian_accepted` carries.

`evm/src/EvmWarden.sol` is the delaying guardian. It is configured in the
constructor (`chainId`, directory, scheduler, delay). The constructor checks
chain id, that the directory has code and reports the same chain, a non-zero
scheduler, and the cap. It does not check that the warden is the directory's
guardian. Service repoints wait `delayBlocks`, fixed when queued, so a later
`setDelay` does not move entries already queued. A directory guardian change
is queued for the same delay, and the directory then waits its own timelock.
`setTimelock` and `cancelAtlasPending` forward immediately. The warden has one
admin slot (delay, scheduler, directory guardian). The directory forward in
`executeAdmin` reverts, and would leave that slot occupied, if the warden is
not the directory's guardian or the directory holds a pending change.
`setGuardian` therefore reverts `NotDirectoryGuardian` or
`DirectoryChangePending` up front, and `setTimelock` reverts
`GuardianChangeQueued` while a directory guardian change is queued, so nothing
can open a directory change in the window. Cancelling the queued entry
(`cancelAdmin`) reopens `setTimelock`.

`setGuardian`, `setScheduler` and the constructors refuse zero, the precompile
range (below `0x100`), the contract itself and the directory
(`ReservedAddress`); the warden refuses exactly what the directory would, so a
queued change cannot fail when forwarded. `scheduleService` requires the
warden to be the directory's guardian, so no repoint is queued, or announced,
that could never execute after a handover. A guardian change (`acceptGuardian`)
and a warden scheduler change (`acceptScheduler`) both wait for the incoming
account to accept, as on native, so a mistyped address can never take the slot.
`acceptAtlasGuardian` lets the scheduler make the warden accept as the incoming
guardian of a directory.

What holds and what does not on EVM:

- The fastest a repoint can land is the warden delay `D` in force when it is
  queued. The fastest a guardian change can land is `D` plus the directory
  timelock `T`.
- `T >= D` is checked by `deploy.sh` for the first pair, and EvmWarden
  keeps it afterwards: `setTimelock` reverts `TimelockBelowDelay` below the
  warden delay (or a queued delay raise), and while the warden is the
  directory's guardian `setDelay` reverts `DelayAboveTimelock` above the
  directory timelock (or a lower pending one). The directory itself does not
  check it, because it never calls its guardian. A compromised scheduler can
  still lower `D` to `0`, wait out the current `D`, and then repoint at once.
  That is the same power a guardian takeover gives in `D + T`. The directory
  timelock does not stop a compromised scheduler.
- A queued entry keeps the `executeAt` it was given; raising the delay later
  does not move it, and it never expires.
- Verify both directions before trusting a pair: `atlas.guardian() == warden`
  and `warden.atlas() == atlas`. `warden.atlas()` alone proves nothing; the
  warden accepts any contract that has code and reports the right chain id.
- `EvmAtlas` records `msg.sender` of its constructor as the only account that
  can call `initGuardian`. Deployed through a factory or any contract that
  cannot make that call, it stays uninitialised for good.
- No event parameter is `indexed`, so logs cannot be filtered by service name.
  `AdminScheduled` reuses `nextScheduler` for the directory's next guardian
  when `changeKind` is 3.
- Blocks are counted, not timed. The 5-minute and 90-day figures assume 2
  second blocks. Checked against the DuskEVM testnet RPC (chain 745) on
  2026-10-20: exactly 2.000 s per block over the last 1,000 blocks, which also
  matches Dusk's documented target. A change to the chain's block time changes
  every delay in wall-clock terms; `evm/script/chain-check.sh` re-measures it.
- The chain (reth 2.3.0, an OP-stack node) accepts every opcode through Cancun
  (`PUSH0`, `MCOPY`, `TLOAD`, `TSTORE`, `BLOBHASH`) and refuses Osaka's `CLZ`
  (`NotActivated`), so it enforces fork boundaries and sits between the two.
  The contracts still build for `paris`, so they need none of those, and run on
  any fork. Mainnet (744) and devnet (310) were not checked: the mainnet RPC
  certificate did not verify and the devnet RPC returned 503.
- `unaliasedSender` is Dusk's own mapping. The Dusk EVM SDK
  (`dusk-network/duskevm-sdk`, `duskContractIdToEvmAddress`) defines the EVM
  address of a Dusk contract id as the last 20 bytes of `keccak256` of the raw
  32-byte id. For a cross-domain message the EVM receiver sees the
  `L2CrossDomainMessenger` as `msg.sender` and reads the Dusk sender from
  `xDomainMessageSender()`; compare that with `unaliasedSender(name)`. Direct
  contract-originated deposits instead apply OP address aliasing to
  `tx.origin`, which is a different value. The end-to-end bridge path was not
  exercised.

The EVM cap is 3,888,000 blocks (90 days at about 2 seconds per block).
`initGuardian`, `setTimelock`, the warden constructor, and `setDelay` all
revert `TimelockTooLong` above it. EvmAtlas 0.4.1
`0x152a7238426B403057aB2c7F2Bbe0B52EF694D90` and EvmWarden 0.4.1
`0x83966e7E879B05f660fab01e09B911651Be4Ef1D` are deployed on DuskEVM testnet
(chain 745). The EvmWarden is the directory's guardian, its scheduler is the
deployer address, and both delays are 150 blocks, which matches the native 5
minutes. See [`evm/README.md`](../evm/README.md).

## Why `execute_pending` is permissionless

Authorization happened at scheduling time. Applying the change after the delay
must not depend on the old key still being online. The new guardian cannot act
until the call runs.
