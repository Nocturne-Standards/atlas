# Design notes

Rationale for choices that look like oversights but are deliberate.

## 1. The kernel is a registry plus one guardian

Atlas is the address consumers bake in. Service logic moves through `resolve` /
`set_service`. Who may write is one `Account`: a BLS key or a contract id.
Committees, per-action delays, and "what this user may do" live in the
guardian contract. That contract calls Atlas. Atlas does not call it.

A closed `GovMode` enum cannot grow a new authority shape without a new
contract id. `Account` is the shape the VM already has (`public_sender` versus
`caller`), so a later guardian contract does not need a new Atlas.

## 2. Only guardian replacement and the delay itself wait

`set_guardian` and `set_timelock` share one pending slot and the current
delay. `set_service` is immediate. A guardian that wants a delay on a service
repoint enforces it before calling `set_service`. That contract is warden.
Its spec is knot `docs/warden.md`. Testnet runs `knot-warden` 0.2.1
`9222e9995febf7fed02a0910a58f7c4190e0f388653ddc8b0d12bb4ef944f607`
in front of Atlas 0.4.1. It queues `set_guardian` in the admin slot for
`delay_blocks`, then Atlas waits its timelock. `set_timelock` and
`cancel_pending` still forward immediately. Earlier wardens (0.1.1 forwarded
`set_guardian` in the same transaction) are history in `CHANGELOG.md`.

The delay stays in the kernel for the guardian because an external contract
that can both authorize and replace itself can delete its own delay. A kernel
delay on that replacement cannot.

`set_timelock` waits for the same reason. An immediate `set_timelock(0)` would
let the guardian rotate itself in the same transaction. Raising and lowering
both wait out the current value. `init_guardian` is the one immediate write of
the delay, because no guardian exists yet. Production `init_guardian` passes
the delay it means to keep. A deployment left at `0` has no kernel delay until
a `set_timelock` is executed.

The bootstrap method is not named `init`. Piecrust treats an exported `init`
as the deploy constructor, calls it during deploy, and rejects every later
call. Guardian and delay are chosen by the deploy owner in a transaction
after deploy, same as v0.2.0 `init_operator`.

## 3. One pending change at a time

`schedule` panics if a change is already stored. A queue would let a guardian
stack several replacements whose combined effect is hard to read, and it would
make `cancel_pending` ambiguous. One slot means one event, one cancel, one
delay. A stored change never expires; execution is permissionless. Service writes do not use the slot, so a pending rotation does not
freeze the directory.

## 4. An external guardian must be a direct account call

`Account::External` requires `public_sender == key` and a direct account call.
A Moonlight transaction always enters through the genesis transfer contract
(`spend_and_execute`, id `reserved(0x1)`), so the call stack below Atlas is
exactly that one contract. A bare session call has an empty stack. Both are
direct. Anything else is a contract using the key, and the call panics.
Checking only `public_sender` would let that contract act as the guardian.

Checking only `caller` is not enough either, and 0.4.1 and older did just
that. The transfer contract can call another contract on behalf of a Moonlight
sender (`contract_to_contract`), and `public_sender` stays the original signer
for the whole transaction. A malicious contract that a key is tricked into
calling could make the transfer contract call Atlas, and Atlas saw `caller ==
transfer contract`, a direct call from the key. Atlas's argument decoding
narrowed the reach to the argument-free calls (`cancel_pending`,
`accept_guardian`) and to `set_timelock`, where only the cap stopped the forged
value (section 8). From 0.5.0 Atlas reads the whole stack with
`abi::callstack()`: the relay path is transfer → relaying contract → transfer,
three frames, and is refused. The same rule covers the deploy owner in
`init_guardian`. It costs one host query per authenticated call.

Naming the transfer contract itself as a `Contract` guardian is rejected
(`guardian contract id reserved`), along with the zero id, any other
genesis-style id, and Atlas's own id: the transfer contract is the `caller` of
every Moonlight transaction, so as a guardian it would make every account the
guardian.

`Account::Contract` checks `caller` and ignores `public_sender`.
The contract decides which users may reach it.

### Handover is two steps

A guardian change waits for the incoming guardian to call `accept_guardian`,
authenticated like a guardian call. Atlas never calls its guardian, so the
acceptance has to be an explicit call by the incoming account. Without it, a
guardian that was mistyped or that never calls Atlas (a valid key nobody holds,
a contract with no code path to Atlas) took the slot and locked every guardian
method, and at delay `0` there was no window to cancel. With it, an account that
cannot act never takes the slot, and the outgoing guardian stays in force and
cancels the stuck change. Acceptance applies the change at once if the delay has
passed, so a delay-zero rotation is two calls: schedule, accept. 0.4.1 added no
event for the acceptance, to keep `atlas-encoding` at 0.3.0, so observers had
to poll `pending_accepted()`. 0.5.0 emits `guardian_accepted`
(`GuardianAccepted { guardian, execute_at }`, `atlas-encoding` 0.4.0), so the
log alone shows who accepted and from when the change can apply.
EvmAtlas `GuardianAccepted` carries the same height as `executeAt`.
`pending_cancelled` carries `execute_at` from atlas 0.6.0
(`atlas-encoding` 0.5.0). Earlier records carry the change only.

## 5. Constants and roles are not in the kernel

A `BTreeMap<String, u64>` cannot hold a `bool` or a `ContractId`, and a value
enum would freeze the next closed set. Parameters and membership belong to the
logic contract `resolve` returns, or to the guardian. Advisory role lists that
Atlas itself never checks are a second product.

## 6. Events carry full payloads

`init_guardian` writes two fields, so it emits `guardian_set` and `timelock_set`.
Every other mutation emits the event for what it wrote. A zero-delay delay
change emits `pending_scheduled` and then the applied event. A guardian change
emits `pending_scheduled`, then `guardian_accepted` when the incoming guardian
accepts (0.5.0 and later), then `guardian_set` once it has accepted and the
delay has passed. Payloads carry the whole
new value so an indexer does not need a follow-up state read.
`set_service` rejects an id already stored under that name, so a repeat does
not emit. From 0.6.0. Types live in
`atlas-encoding` with layout goldens.

## 7. Never upgraded; consumers bake the id in

Consumers read the Atlas id from a build-time constant (`ATLAS_PIN_HEX`
through `build.rs`). A new deployment is a new trust anchor.
`PINNED-DIFFERENT-REDEPLOYED` in the changelog marks when that happens.
v0.2.0 ids stay on the old kernel until an operator redeploys.

## 8. Cap the timelock, and cap native names

A huge `timelock_blocks` makes every later schedule fail the overflow check.
Guardian rotation and delay changes are then frozen. The likely way there is
a units mistake, such as passing seconds where blocks are expected.

Atlas rejects a delay above 777,600 blocks in `init_guardian` and in
`set_timelock`, with panic `timelock above maximum`. The overflow check
stays. EvmAtlas and EvmWarden use 3,888,000 blocks, which is the same 90 days
at DuskEVM's shorter block time, and revert `TimelockTooLong`. The warden
delay on both chains uses the same cap as the directory on that chain.

`set_service` on native Atlas rejects an empty name and a name longer than
64 bytes. Every name in use fits. 0.4.1 also rejects an all-zero service id
and a zero `Account::Contract` guardian, as EvmAtlas does for its zero
locator and guardian. A key cannot be zero-checked, and no name can be
removed. (`atlas-encoding` stayed at 0.3.0 for those; it moves to 0.4.0 with
the `guardian_accepted` event in 0.5.0.)

The cap has a second job on 0.4.1 and older. A contract that reaches Atlas
through `contract_to_contract` (section 4) can make `set_timelock` decode a
`u64` from the relay's own argument; that value is a pointer and length, always
above 2^31, so `timelock above maximum` refuses it. Without the cap, such a
relay could schedule a bogus delay change and occupy the single slot. From
0.5.0 the call-depth test refuses the relay before decoding matters, and the
cap is back to guarding against unit mistakes.
Older deployed instances keep their old acceptance rules; `CHANGELOG.md`
lists what each version checks.

## 9. `execute_pending` is permissionless

The guardian authorized the change when it scheduled it. Applying it after the
delay is mechanical. Anyone may pay for it, including after the old key is
gone. The new guardian is not authority until this call. `cancel_pending`
stays with the current guardian so an honest guardian can abort a rotation.
The delay slows a hostile apply. It does not stop an attacker who still holds
the current guardian.
