//! Atlas host-side tests (guardian gate + timelock).

extern crate alloc;

use alloc::string::String;
use alloc::vec::Vec;

use dusk_bytes::Serializable;
use dusk_core::abi::{ContractId, Event, Metadata};
use dusk_core::signatures::bls::{PublicKey as BlsPublicKey, SecretKey as BlsSecretKey};
use dusk_core::transfer::TRANSFER_CONTRACT;
use dusk_vm::{CallReceipt, ContractData, Session, VM};
use rand::SeedableRng;
use rand::rngs::StdRng;
use rkyv::Deserialize;

use atlas_encoding::call_types::{Account, InitArgs, PendingChange, PendingView, SetServiceArgs};
use atlas_encoding::events::{
    GuardianAccepted, GuardianSet, PendingCancelled, PendingScheduled, ServiceUpdated, TimelockSet,
};

const ATLAS_BYTECODE: &[u8] =
    include_bytes!("../../../target/contract/wasm32-unknown-unknown/release/atlas.wasm");
const PROXY_BYTECODE: &[u8] =
    include_bytes!("../../../target/contract/wasm32-unknown-unknown/release/atlas_test_proxy.wasm");

const ATLAS_ID: ContractId = ContractId::from_bytes([0xa7; 32]);
const PROXY_ID: ContractId = ContractId::from_bytes([0xa8; 32]);
const SERVICE_ID: ContractId = ContractId::from_bytes([0x11; 32]);
const CHAIN_ID: u8 = 0xCA;
const POINT_LIMIT: u64 = 0x10000000;

fn keypair(rng: &mut StdRng) -> (BlsSecretKey, BlsPublicKey) {
    let sk = BlsSecretKey::random(rng);
    let pk = BlsPublicKey::from(&sk);
    (sk, pk)
}

fn set_sender(session: &mut Session, sender: Option<&BlsPublicKey>) {
    session
        .set_meta(Metadata::PUBLIC_SENDER, sender.copied())
        .expect("setting public_sender metadata should succeed");
}

fn set_height(session: &mut Session, h: u64) {
    session
        .set_meta(Metadata::BLOCK_HEIGHT, h)
        .expect("setting block_height metadata should succeed");
}

fn deploy(owner_pk: &BlsPublicKey) -> Session {
    let vm = VM::ephemeral().expect("ephemeral VM");
    let mut session = vm.genesis_session(CHAIN_ID);
    let _: (ContractId, Option<CallReceipt<()>>) = session
        .deploy(
            ATLAS_BYTECODE,
            ContractData::builder()
                .owner(owner_pk.to_bytes().to_vec())
                .contract_id(ATLAS_ID),
            POINT_LIMIT,
        )
        .expect("deploy atlas");
    let _: (ContractId, Option<CallReceipt<()>>) = session
        .deploy(
            PROXY_BYTECODE,
            ContractData::builder()
                .owner(owner_pk.to_bytes().to_vec())
                .contract_id(PROXY_ID),
            POINT_LIMIT,
        )
        .expect("deploy proxy");
    // genesis_session stores the height as an untyped 0 (4 bytes). Contracts
    // read a u64, and uplink 0.21 rejects the short value.
    session
        .set_meta(Metadata::BLOCK_HEIGHT, 0u64)
        .expect("setting block_height metadata should succeed");
    session
}

fn event<'a, T>(receipt: &'a CallReceipt<T>, topic: &str) -> &'a Event {
    let hits: Vec<_> = receipt
        .events
        .iter()
        .filter(|e| e.source == ATLAS_ID && e.topic == topic)
        .collect();
    assert_eq!(
        hits.len(),
        1,
        "expected one {topic} from ATLAS_ID; topics={:?}",
        receipt
            .events
            .iter()
            .map(|e| (e.source, e.topic.as_str()))
            .collect::<Vec<_>>()
    );
    hits[0]
}

fn decode_event<T>(ev: &Event) -> T
where
    T: rkyv::Archive,
    T::Archived: Deserialize<T, rkyv::Infallible>
        + for<'b> bytecheck::CheckBytes<rkyv::validation::validators::DefaultValidator<'b>>,
{
    let archived = rkyv::check_archived_root::<T>(&ev.data)
        .unwrap_or_else(|e| panic!("archive {}: {e}", ev.topic));
    archived
        .deserialize(&mut rkyv::Infallible)
        .unwrap_or_else(|_| panic!("deserialize {}", ev.topic))
}

fn atlas_topics<T>(receipt: &CallReceipt<T>) -> Vec<&str> {
    receipt
        .events
        .iter()
        .filter(|e| e.source == ATLAS_ID)
        .map(|e| e.topic.as_str())
        .collect()
}

fn init(session: &mut Session, owner: &BlsPublicKey, guardian: Account, timelock_blocks: u64) {
    set_sender(session, Some(owner));
    session
        .call::<InitArgs, ()>(
            ATLAS_ID,
            "init_guardian",
            &InitArgs {
                guardian,
                timelock_blocks,
            },
            POINT_LIMIT,
        )
        .expect("init_guardian");
}

fn service(name: &str, id: ContractId) -> SetServiceArgs {
    SetServiceArgs {
        name: String::from(name),
        id,
    }
}

fn guardian_of(session: &mut Session) -> Option<Account> {
    session
        .call::<(), Option<Account>>(ATLAS_ID, "guardian", &(), POINT_LIMIT)
        .expect("guardian")
        .data
}

fn accept(session: &mut Session, key: &BlsPublicKey) -> Result<(), dusk_vm::Error> {
    set_sender(session, Some(key));
    session
        .call::<(), ()>(ATLAS_ID, "accept_guardian", &(), POINT_LIMIT)
        .map(|_| ())
}

fn pending_accepted(session: &mut Session) -> bool {
    session
        .call::<(), bool>(ATLAS_ID, "pending_accepted", &(), POINT_LIMIT)
        .expect("pending_accepted")
        .data
}

fn assert_panics(err: impl core::fmt::Debug, needle: &str) {
    let text = format!("{err:?}");
    assert!(
        text.contains(needle),
        "expected panic containing {needle:?}, got {text}"
    );
}

#[test]
fn init_is_owner_once() {
    let rng = &mut StdRng::seed_from_u64(1);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let (_, other) = keypair(rng);
    let session = &mut deploy(&owner);

    set_sender(session, Some(&other));
    let denied = session.call::<InitArgs, ()>(
        ATLAS_ID,
        "init_guardian",
        &InitArgs {
            guardian: Account::External(op),
            timelock_blocks: 0,
        },
        POINT_LIMIT,
    );
    assert!(denied.is_err(), "non-owner init must fail");

    init(session, &owner, Account::External(op), 0);
    let guardian = session
        .call::<(), Option<Account>>(ATLAS_ID, "guardian", &(), POINT_LIMIT)
        .expect("guardian")
        .data;
    assert_eq!(guardian, Some(Account::External(op)));

    set_sender(session, Some(&owner));
    let second = session.call::<InitArgs, ()>(
        ATLAS_ID,
        "init_guardian",
        &InitArgs {
            guardian: Account::External(other),
            timelock_blocks: 0,
        },
        POINT_LIMIT,
    );
    assert!(second.is_err(), "second init must fail");
}

#[test]
fn uninitialized_writes_panic_reads_are_empty() {
    let rng = &mut StdRng::seed_from_u64(2);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let session = &mut deploy(&owner);

    assert!(
        session
            .call::<(), Option<Account>>(ATLAS_ID, "guardian", &(), POINT_LIMIT)
            .unwrap()
            .data
            .is_none()
    );
    assert_eq!(
        session
            .call::<(), u64>(ATLAS_ID, "timelock_blocks", &(), POINT_LIMIT)
            .unwrap()
            .data,
        0
    );
    set_sender(session, Some(&op));
    assert!(
        session
            .call::<SetServiceArgs, ()>(
                ATLAS_ID,
                "set_service",
                &service("treasury", SERVICE_ID),
                POINT_LIMIT,
            )
            .is_err()
    );
}

#[test]
fn external_guardian_sets_service_immediately() {
    let rng = &mut StdRng::seed_from_u64(3);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let (_, other) = keypair(rng);
    let session = &mut deploy(&owner);
    init(session, &owner, Account::External(op), 0);

    set_sender(session, Some(&other));
    assert!(
        session
            .call::<SetServiceArgs, ()>(
                ATLAS_ID,
                "set_service",
                &service("treasury", SERVICE_ID),
                POINT_LIMIT,
            )
            .is_err()
    );

    set_sender(session, Some(&op));
    session
        .call::<SetServiceArgs, ()>(
            ATLAS_ID,
            "set_service",
            &service("treasury", SERVICE_ID),
            POINT_LIMIT,
        )
        .expect("set_service");
    let resolved = session
        .call::<String, Option<ContractId>>(
            ATLAS_ID,
            "resolve",
            &String::from("treasury"),
            POINT_LIMIT,
        )
        .expect("resolve")
        .data;
    assert_eq!(resolved, Some(SERVICE_ID));
}

#[test]
fn external_guardian_rejects_inter_contract_call() {
    let rng = &mut StdRng::seed_from_u64(4);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let session = &mut deploy(&owner);
    init(session, &owner, Account::External(op), 0);

    // public_sender is the guardian, but caller is the proxy.
    set_sender(session, Some(&op));
    let err = session.call::<(ContractId, String, ContractId), ()>(
        PROXY_ID,
        "call_set_service",
        &(ATLAS_ID, String::from("treasury"), SERVICE_ID),
        POINT_LIMIT,
    );
    // The proxy call itself fails because Atlas panics inside the cross-call.
    assert!(err.is_err(), "contract must not wield an external guardian");
    let resolved = session
        .call::<String, Option<ContractId>>(
            ATLAS_ID,
            "resolve",
            &String::from("treasury"),
            POINT_LIMIT,
        )
        .unwrap()
        .data;
    assert!(resolved.is_none());
}

#[test]
fn external_guardian_accepts_transfer_contract_caller() {
    let rng = &mut StdRng::seed_from_u64(41);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let session = &mut deploy(&owner);
    let _: (ContractId, Option<CallReceipt<()>>) = session
        .deploy(
            PROXY_BYTECODE,
            ContractData::builder()
                .owner(owner.to_bytes().to_vec())
                .contract_id(TRANSFER_CONTRACT),
            POINT_LIMIT,
        )
        .expect("deploy proxy at the transfer contract id");

    set_sender(session, Some(&owner));
    session
        .call::<(ContractId, InitArgs), ()>(
            TRANSFER_CONTRACT,
            "call_init_guardian",
            &(
                ATLAS_ID,
                InitArgs {
                    guardian: Account::External(op),
                    timelock_blocks: 0,
                },
            ),
            POINT_LIMIT,
        )
        .expect("init_guardian via transfer contract");

    set_sender(session, Some(&op));
    session
        .call::<(ContractId, String, ContractId), ()>(
            TRANSFER_CONTRACT,
            "call_set_service",
            &(ATLAS_ID, String::from("treasury"), SERVICE_ID),
            POINT_LIMIT,
        )
        .expect("set_service via transfer contract");
    let resolved = session
        .call::<String, Option<ContractId>>(
            ATLAS_ID,
            "resolve",
            &String::from("treasury"),
            POINT_LIMIT,
        )
        .unwrap()
        .data;
    assert_eq!(resolved, Some(SERVICE_ID));
}

#[test]
fn contract_guardian_accepts_only_that_caller() {
    let rng = &mut StdRng::seed_from_u64(5);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let session = &mut deploy(&owner);
    init(session, &owner, Account::External(op), 0);

    set_sender(session, Some(&op));
    session
        .call::<Account, ()>(
            ATLAS_ID,
            "set_guardian",
            &Account::Contract(PROXY_ID),
            POINT_LIMIT,
        )
        .expect("rotate to proxy");

    // Scheduled, not applied: the incoming contract has to accept first, and a
    // key cannot accept for a contract guardian.
    assert_eq!(guardian_of(session), Some(Account::External(op)));
    assert_panics(
        accept(session, &op).expect_err("key accepts for a contract"),
        "Contract incoming guardian: caller must be the incoming guardian contract",
    );
    session
        .call::<ContractId, ()>(PROXY_ID, "call_accept_guardian", &ATLAS_ID, POINT_LIMIT)
        .expect("proxy accepts");
    assert_eq!(guardian_of(session), Some(Account::Contract(PROXY_ID)));

    set_sender(session, Some(&op));
    let direct = session.call::<SetServiceArgs, ()>(
        ATLAS_ID,
        "set_service",
        &service("treasury", SERVICE_ID),
        POINT_LIMIT,
    );
    assert!(
        direct.is_err(),
        "direct call must fail for a contract guardian"
    );

    session
        .call::<(ContractId, String, ContractId), ()>(
            PROXY_ID,
            "call_set_service",
            &(ATLAS_ID, String::from("treasury"), SERVICE_ID),
            POINT_LIMIT,
        )
        .expect("proxy set_service");
    let resolved = session
        .call::<String, Option<ContractId>>(
            ATLAS_ID,
            "resolve",
            &String::from("treasury"),
            POINT_LIMIT,
        )
        .unwrap()
        .data;
    assert_eq!(resolved, Some(SERVICE_ID));
}

#[test]
fn zero_delay_guardian_replacement_applies_on_acceptance() {
    let rng = &mut StdRng::seed_from_u64(6);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let (_, next) = keypair(rng);
    let session = &mut deploy(&owner);
    init(session, &owner, Account::External(op), 0);

    set_sender(session, Some(&op));
    session
        .call::<Account, ()>(
            ATLAS_ID,
            "set_guardian",
            &Account::External(next),
            POINT_LIMIT,
        )
        .expect("set_guardian");
    // Even at delay zero the change waits for the incoming guardian.
    assert_eq!(guardian_of(session), Some(Account::External(op)));
    assert!(!pending_accepted(session));
    // Neither the outgoing guardian nor a stranger can accept for `next`.
    assert_panics(
        accept(session, &op).expect_err("outgoing guardian accepts"),
        "Only the atlas incoming guardian may perform this action",
    );
    set_sender(session, None);
    assert!(
        session
            .call::<(), ()>(ATLAS_ID, "execute_pending", &(), POINT_LIMIT)
            .is_err(),
        "execute_pending cannot apply an unaccepted guardian change"
    );
    accept(session, &next).expect("incoming guardian accepts");
    assert_eq!(guardian_of(session), Some(Account::External(next)));
    assert!(!pending_accepted(session));

    set_sender(session, Some(&op));
    assert!(
        session
            .call::<SetServiceArgs, ()>(
                ATLAS_ID,
                "set_service",
                &service("treasury", SERVICE_ID),
                POINT_LIMIT,
            )
            .is_err()
    );
    set_sender(session, Some(&next));
    session
        .call::<SetServiceArgs, ()>(
            ATLAS_ID,
            "set_service",
            &service("treasury", SERVICE_ID),
            POINT_LIMIT,
        )
        .expect("new guardian writes");
}

#[test]
fn timelock_delays_guardian_and_cancel_keeps_old_authority() {
    let rng = &mut StdRng::seed_from_u64(7);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let (_, next) = keypair(rng);
    let session = &mut deploy(&owner);
    init(session, &owner, Account::External(op), 0);

    set_sender(session, Some(&op));
    set_height(session, 0);
    session
        .call::<u64, ()>(ATLAS_ID, "set_timelock", &5u64, POINT_LIMIT)
        .expect("raise delay from 0");
    assert_eq!(
        session
            .call::<(), u64>(ATLAS_ID, "timelock_blocks", &(), POINT_LIMIT)
            .unwrap()
            .data,
        5
    );

    session
        .call::<Account, ()>(
            ATLAS_ID,
            "set_guardian",
            &Account::External(next),
            POINT_LIMIT,
        )
        .expect("schedule set_guardian");
    let pending = session
        .call::<(), Option<PendingView>>(ATLAS_ID, "pending", &(), POINT_LIMIT)
        .unwrap()
        .data
        .expect("pending");
    assert_eq!(
        pending.change,
        PendingChange::Guardian(Account::External(next))
    );
    assert_eq!(pending.execute_at, 5);

    set_height(session, 4);
    assert!(
        session
            .call::<(), ()>(ATLAS_ID, "execute_pending", &(), POINT_LIMIT)
            .is_err()
    );

    // Scheduled key cannot write. Current guardian still can, including service
    // updates, which do not touch the pending slot.
    set_sender(session, Some(&next));
    assert!(
        session
            .call::<SetServiceArgs, ()>(
                ATLAS_ID,
                "set_service",
                &service("treasury", SERVICE_ID),
                POINT_LIMIT,
            )
            .is_err()
    );
    set_sender(session, Some(&op));
    session
        .call::<SetServiceArgs, ()>(
            ATLAS_ID,
            "set_service",
            &service("treasury", SERVICE_ID),
            POINT_LIMIT,
        )
        .expect("old guardian set_service during pending rotation");
    assert_eq!(
        session
            .call::<String, Option<ContractId>>(
                ATLAS_ID,
                "resolve",
                &String::from("treasury"),
                POINT_LIMIT,
            )
            .unwrap()
            .data,
        Some(SERVICE_ID)
    );
    assert!(
        session
            .call::<(), Option<PendingView>>(ATLAS_ID, "pending", &(), POINT_LIMIT)
            .unwrap()
            .data
            .is_some()
    );

    session
        .call::<(), ()>(ATLAS_ID, "cancel_pending", &(), POINT_LIMIT)
        .expect("cancel");
    assert!(
        session
            .call::<(), Option<PendingView>>(ATLAS_ID, "pending", &(), POINT_LIMIT)
            .unwrap()
            .data
            .is_none()
    );
    assert_eq!(
        session
            .call::<(), Option<Account>>(ATLAS_ID, "guardian", &(), POINT_LIMIT)
            .unwrap()
            .data,
        Some(Account::External(op))
    );
}

#[test]
fn anyone_may_execute_after_delay() {
    let rng = &mut StdRng::seed_from_u64(8);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let (_, next) = keypair(rng);
    let (_, stranger) = keypair(rng);
    let session = &mut deploy(&owner);
    init(session, &owner, Account::External(op), 5);

    set_sender(session, Some(&op));
    set_height(session, 0);
    session
        .call::<Account, ()>(
            ATLAS_ID,
            "set_guardian",
            &Account::External(next),
            POINT_LIMIT,
        )
        .expect("schedule");

    // The incoming guardian accepts early; the change still waits out the delay.
    set_height(session, 1);
    accept(session, &next).expect("accept before the delay passes");
    assert!(pending_accepted(session));
    assert_eq!(guardian_of(session), Some(Account::External(op)));
    set_height(session, 4);
    set_sender(session, Some(&stranger));
    assert!(
        session
            .call::<(), ()>(ATLAS_ID, "execute_pending", &(), POINT_LIMIT)
            .is_err()
    );

    set_height(session, 5);
    set_sender(session, Some(&stranger));
    session
        .call::<(), ()>(ATLAS_ID, "execute_pending", &(), POINT_LIMIT)
        .expect("permissionless execute");
    assert!(
        session
            .call::<(), Option<PendingView>>(ATLAS_ID, "pending", &(), POINT_LIMIT)
            .unwrap()
            .data
            .is_none()
    );
    assert_eq!(
        session
            .call::<(), Option<Account>>(ATLAS_ID, "guardian", &(), POINT_LIMIT)
            .unwrap()
            .data,
        Some(Account::External(next))
    );

    set_sender(session, Some(&next));
    session
        .call::<SetServiceArgs, ()>(
            ATLAS_ID,
            "set_service",
            &service("treasury", SERVICE_ID),
            POINT_LIMIT,
        )
        .expect("new guardian");
    set_sender(session, Some(&op));
    assert!(
        session
            .call::<SetServiceArgs, ()>(
                ATLAS_ID,
                "set_service",
                &service("other", SERVICE_ID),
                POINT_LIMIT,
            )
            .is_err()
    );
}

#[test]
fn set_timelock_from_nonzero_waits_and_occupies_the_slot() {
    let rng = &mut StdRng::seed_from_u64(9);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let (_, next) = keypair(rng);
    let session = &mut deploy(&owner);
    init(session, &owner, Account::External(op), 0);

    set_sender(session, Some(&op));
    set_height(session, 0);
    session
        .call::<u64, ()>(ATLAS_ID, "set_timelock", &5u64, POINT_LIMIT)
        .expect("raise from 0");

    session
        .call::<u64, ()>(ATLAS_ID, "set_timelock", &9u64, POINT_LIMIT)
        .expect("schedule raise to 9");
    let pending = session
        .call::<(), Option<PendingView>>(ATLAS_ID, "pending", &(), POINT_LIMIT)
        .unwrap()
        .data
        .expect("pending timelock");
    assert_eq!(pending.change, PendingChange::Timelock(9));
    assert_eq!(pending.execute_at, 5);
    assert_eq!(
        session
            .call::<(), u64>(ATLAS_ID, "timelock_blocks", &(), POINT_LIMIT)
            .unwrap()
            .data,
        5,
        "delay stays until execute"
    );

    let occupied = session.call::<Account, ()>(
        ATLAS_ID,
        "set_guardian",
        &Account::External(next),
        POINT_LIMIT,
    );
    assert!(occupied.is_err(), "pending slot is taken");
}

#[test]
fn unchanged_guardian_or_delay_does_not_schedule() {
    let rng = &mut StdRng::seed_from_u64(10);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let session = &mut deploy(&owner);
    init(session, &owner, Account::External(op), 4);

    set_sender(session, Some(&op));
    assert!(
        session
            .call::<Account, ()>(
                ATLAS_ID,
                "set_guardian",
                &Account::External(op),
                POINT_LIMIT,
            )
            .is_err()
    );
    assert!(
        session
            .call::<u64, ()>(ATLAS_ID, "set_timelock", &4u64, POINT_LIMIT)
            .is_err()
    );
    assert!(
        session
            .call::<(), Option<PendingView>>(ATLAS_ID, "pending", &(), POINT_LIMIT)
            .unwrap()
            .data
            .is_none()
    );
}

#[test]
fn mutating_methods_emit_typed_events() {
    let rng = &mut StdRng::seed_from_u64(11);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let (_, next) = keypair(rng);
    let session = &mut deploy(&owner);

    set_sender(session, Some(&owner));
    let init_rc = session
        .call::<InitArgs, ()>(
            ATLAS_ID,
            "init_guardian",
            &InitArgs {
                guardian: Account::External(op),
                timelock_blocks: 0,
            },
            POINT_LIMIT,
        )
        .expect("init_guardian");
    assert_eq!(atlas_topics(&init_rc), ["guardian_set", "timelock_set"]);
    let g_ev = decode_event::<GuardianSet>(event(&init_rc, "guardian_set"));
    assert_eq!(g_ev.guardian, Account::External(op));
    let tl_ev = decode_event::<TimelockSet>(event(&init_rc, "timelock_set"));
    assert_eq!(tl_ev.blocks, 0);

    set_sender(session, Some(&op));
    let set_svc = session
        .call::<SetServiceArgs, ()>(
            ATLAS_ID,
            "set_service",
            &service("treasury", SERVICE_ID),
            POINT_LIMIT,
        )
        .expect("set_service");
    assert_eq!(atlas_topics(&set_svc), ["service_updated"]);
    let svc_ev = decode_event::<ServiceUpdated>(event(&set_svc, "service_updated"));
    assert_eq!(svc_ev.name, "treasury");
    assert_eq!(svc_ev.id, SERVICE_ID);

    set_height(session, 0);
    let set_tl = session
        .call::<u64, ()>(ATLAS_ID, "set_timelock", &5u64, POINT_LIMIT)
        .expect("set_timelock");
    assert_eq!(atlas_topics(&set_tl), ["pending_scheduled", "timelock_set"]);
    let sched_tl = decode_event::<PendingScheduled>(event(&set_tl, "pending_scheduled"));
    assert_eq!(sched_tl.change, PendingChange::Timelock(5));
    assert_eq!(sched_tl.execute_at, 0);
    let applied_tl = decode_event::<TimelockSet>(event(&set_tl, "timelock_set"));
    assert_eq!(applied_tl.blocks, 5);

    let set_g = session
        .call::<Account, ()>(
            ATLAS_ID,
            "set_guardian",
            &Account::External(next),
            POINT_LIMIT,
        )
        .expect("schedule set_guardian");
    assert_eq!(atlas_topics(&set_g), ["pending_scheduled"]);
    let sched_g = decode_event::<PendingScheduled>(event(&set_g, "pending_scheduled"));
    assert_eq!(
        sched_g.change,
        PendingChange::Guardian(Account::External(next))
    );
    assert_eq!(sched_g.execute_at, 5);

    let cancel = session
        .call::<(), ()>(ATLAS_ID, "cancel_pending", &(), POINT_LIMIT)
        .expect("cancel");
    let cancel_ev = decode_event::<PendingCancelled>(event(&cancel, "pending_cancelled"));
    assert_eq!(
        cancel_ev.change,
        PendingChange::Guardian(Account::External(next))
    );
    assert_eq!(cancel_ev.execute_at, 5);

    session
        .call::<Account, ()>(
            ATLAS_ID,
            "set_guardian",
            &Account::External(next),
            POINT_LIMIT,
        )
        .expect("schedule again");
    let accepted = {
        set_sender(session, Some(&next));
        session
            .call::<(), ()>(ATLAS_ID, "accept_guardian", &(), POINT_LIMIT)
            .expect("accept before the delay passes")
    };
    assert_eq!(atlas_topics(&accepted), ["guardian_accepted"]);
    let accepted_ev = decode_event::<GuardianAccepted>(event(&accepted, "guardian_accepted"));
    assert_eq!(accepted_ev.guardian, Account::External(next));
    assert_eq!(accepted_ev.execute_at, 5);
    set_height(session, 5);
    set_sender(session, None);
    let applied = session
        .call::<(), ()>(ATLAS_ID, "execute_pending", &(), POINT_LIMIT)
        .expect("execute");
    assert_eq!(atlas_topics(&applied), ["guardian_set"]);
    let applied_g = decode_event::<GuardianSet>(event(&applied, "guardian_set"));
    assert_eq!(applied_g.guardian, Account::External(next));
}

const MAX_TIMELOCK_BLOCKS: u64 = 777_600;

#[test]
fn timelock_cap_rejects_init_and_schedule() {
    let rng = &mut StdRng::seed_from_u64(20);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let session = &mut deploy(&owner);

    set_sender(session, Some(&owner));
    let over = session.call::<InitArgs, ()>(
        ATLAS_ID,
        "init_guardian",
        &InitArgs {
            guardian: Account::External(op),
            timelock_blocks: MAX_TIMELOCK_BLOCKS + 1,
        },
        POINT_LIMIT,
    );
    assert_panics(over.expect_err("cap"), "timelock above maximum");

    init(session, &owner, Account::External(op), MAX_TIMELOCK_BLOCKS);
    let delay = session
        .call::<(), u64>(ATLAS_ID, "timelock_blocks", &(), POINT_LIMIT)
        .unwrap()
        .data;
    assert_eq!(delay, MAX_TIMELOCK_BLOCKS);

    set_sender(session, Some(&op));
    let scheduled = session.call::<u64, ()>(
        ATLAS_ID,
        "set_timelock",
        &(MAX_TIMELOCK_BLOCKS + 1),
        POINT_LIMIT,
    );
    assert_panics(scheduled.expect_err("cap"), "timelock above maximum");
    assert!(
        session
            .call::<(), Option<PendingView>>(ATLAS_ID, "pending", &(), POINT_LIMIT)
            .unwrap()
            .data
            .is_none()
    );
}

#[test]
fn set_service_rejects_empty_and_long_names() {
    let rng = &mut StdRng::seed_from_u64(21);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let session = &mut deploy(&owner);
    init(session, &owner, Account::External(op), 0);
    set_sender(session, Some(&op));

    let empty = session.call::<SetServiceArgs, ()>(
        ATLAS_ID,
        "set_service",
        &service("", SERVICE_ID),
        POINT_LIMIT,
    );
    assert_panics(empty.expect_err("empty"), "name empty");

    let long = session.call::<SetServiceArgs, ()>(
        ATLAS_ID,
        "set_service",
        &service(&"a".repeat(65), SERVICE_ID),
        POINT_LIMIT,
    );
    assert_panics(long.expect_err("long"), "name longer than 64 bytes");

    session
        .call::<SetServiceArgs, ()>(
            ATLAS_ID,
            "set_service",
            &service(&"b".repeat(64), SERVICE_ID),
            POINT_LIMIT,
        )
        .expect("64 bytes");
    let resolved = session
        .call::<String, Option<ContractId>>(ATLAS_ID, "resolve", &"b".repeat(64), POINT_LIMIT)
        .expect("resolve")
        .data;
    assert_eq!(resolved, Some(SERVICE_ID));
}

#[test]
fn set_service_rejects_an_id_already_stored() {
    let rng = &mut StdRng::seed_from_u64(21);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let other = ContractId::from_bytes([0x22; 32]);
    let session = &mut deploy(&owner);
    init(session, &owner, Account::External(op), 0);
    set_sender(session, Some(&op));

    session
        .call::<SetServiceArgs, ()>(
            ATLAS_ID,
            "set_service",
            &service("treasury", SERVICE_ID),
            POINT_LIMIT,
        )
        .expect("first set");
    let again = session.call::<SetServiceArgs, ()>(
        ATLAS_ID,
        "set_service",
        &service("treasury", SERVICE_ID),
        POINT_LIMIT,
    );
    assert_panics(again.expect_err("unchanged"), "service unchanged");
    let resolved = session
        .call::<String, Option<ContractId>>(
            ATLAS_ID,
            "resolve",
            &"treasury".to_string(),
            POINT_LIMIT,
        )
        .expect("resolve")
        .data;
    assert_eq!(resolved, Some(SERVICE_ID));

    session
        .call::<SetServiceArgs, ()>(
            ATLAS_ID,
            "set_service",
            &service("treasury", other),
            POINT_LIMIT,
        )
        .expect("repoint");
    let moved = session
        .call::<String, Option<ContractId>>(
            ATLAS_ID,
            "resolve",
            &"treasury".to_string(),
            POINT_LIMIT,
        )
        .expect("resolve after repoint")
        .data;
    assert_eq!(moved, Some(other));
}

#[test]
fn zero_ids_are_rejected() {
    let zero = ContractId::from_bytes([0u8; 32]);
    let rng = &mut StdRng::seed_from_u64(22);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let session = &mut deploy(&owner);

    set_sender(session, Some(&owner));
    let denied = session.call::<InitArgs, ()>(
        ATLAS_ID,
        "init_guardian",
        &InitArgs {
            guardian: Account::Contract(zero),
            timelock_blocks: 0,
        },
        POINT_LIMIT,
    );
    assert_panics(
        denied.expect_err("zero guardian"),
        "guardian contract id zero",
    );

    init(session, &owner, Account::External(op), 0);
    set_sender(session, Some(&op));

    let zero_service = session.call::<SetServiceArgs, ()>(
        ATLAS_ID,
        "set_service",
        &service("treasury", zero),
        POINT_LIMIT,
    );
    assert_panics(zero_service.expect_err("zero service"), "service id zero");

    let zero_rotation = session.call::<Account, ()>(
        ATLAS_ID,
        "set_guardian",
        &Account::Contract(zero),
        POINT_LIMIT,
    );
    assert_panics(
        zero_rotation.expect_err("zero rotation"),
        "guardian contract id zero",
    );

    let resolved = session
        .call::<String, Option<ContractId>>(
            ATLAS_ID,
            "resolve",
            &String::from("treasury"),
            POINT_LIMIT,
        )
        .expect("resolve")
        .data;
    assert_eq!(resolved, None);
}

#[test]
fn reserved_and_unusable_guardians_are_rejected() {
    let rng = &mut StdRng::seed_from_u64(23);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let session = &mut deploy(&owner);

    let mut stake_style = [0u8; 32];
    stake_style[0] = 2;
    let cases = [
        // Every Moonlight transaction has the transfer contract as its caller.
        (TRANSFER_CONTRACT, "guardian contract id reserved"),
        (
            ContractId::from_bytes(stake_style),
            "guardian contract id reserved",
        ),
        // Atlas never calls out, so its own id never matches `caller`.
        (ATLAS_ID, "guardian cannot be atlas itself"),
    ];
    for (id, needle) in cases {
        set_sender(session, Some(&owner));
        let denied = session.call::<InitArgs, ()>(
            ATLAS_ID,
            "init_guardian",
            &InitArgs {
                guardian: Account::Contract(id),
                timelock_blocks: 0,
            },
            POINT_LIMIT,
        );
        assert_panics(denied.expect_err("init"), needle);
    }

    init(session, &owner, Account::External(op), 0);
    for (id, needle) in cases {
        set_sender(session, Some(&op));
        let denied = session.call::<Account, ()>(
            ATLAS_ID,
            "set_guardian",
            &Account::Contract(id),
            POINT_LIMIT,
        );
        assert_panics(denied.expect_err("set_guardian"), needle);
    }
    let guardian = session
        .call::<(), Option<Account>>(ATLAS_ID, "guardian", &(), POINT_LIMIT)
        .expect("guardian")
        .data;
    assert_eq!(guardian, Some(Account::External(op)));
}

/// The archived BLS key type only checks length, not that the bytes are a curve
/// point. A garbage key would lock the guardian slot for good.
#[test]
fn off_curve_external_key_is_rejected() {
    use rkyv::ser::Serializer;
    use rkyv::ser::serializers::AllocSerializer;

    let rng = &mut StdRng::seed_from_u64(24);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let session = &mut deploy(&owner);
    init(session, &owner, Account::External(op), 0);

    let mut ser = AllocSerializer::<256>::default();
    ser.serialize_value(&Account::External(op))
        .expect("serialize");
    let mut bytes = ser.into_serializer().into_inner().to_vec();
    let len = bytes.len();
    for b in &mut bytes[8..len - 8] {
        *b = 0x5a;
    }

    set_sender(session, Some(&op));
    let denied = session.call_raw(ATLAS_ID, "set_guardian", bytes, POINT_LIMIT);
    assert_panics(denied.expect_err("garbage key"), "guardian key invalid");

    // The guardian is unchanged and can still act.
    set_sender(session, Some(&op));
    session
        .call::<SetServiceArgs, ()>(
            ATLAS_ID,
            "set_service",
            &service("treasury", SERVICE_ID),
            POINT_LIMIT,
        )
        .expect("original guardian still works");
}

#[test]
fn unaccepted_guardian_change_cannot_take_the_slot() {
    let rng = &mut StdRng::seed_from_u64(25);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let (_, typo) = keypair(rng);
    let (_, other) = keypair(rng);
    let session = &mut deploy(&owner);
    init(session, &owner, Account::External(op), 5);

    // A valid key nobody controls (a mistyped address) is scheduled as guardian.
    set_height(session, 0);
    set_sender(session, Some(&op));
    session
        .call::<Account, ()>(
            ATLAS_ID,
            "set_guardian",
            &Account::External(typo),
            POINT_LIMIT,
        )
        .expect("schedule");

    // Nobody else can accept for it, at any height, and execute_pending refuses.
    set_height(session, 100);
    assert_panics(
        accept(session, &other).expect_err("other accepts"),
        "Only the atlas incoming guardian may perform this action",
    );
    set_sender(session, None);
    let refused = session.call::<(), ()>(ATLAS_ID, "execute_pending", &(), POINT_LIMIT);
    assert_panics(
        refused.expect_err("execute"),
        "incoming guardian has not accepted",
    );
    assert_eq!(guardian_of(session), Some(Account::External(op)));

    // The current guardian still acts, and cancels the stuck change.
    set_sender(session, Some(&op));
    session
        .call::<SetServiceArgs, ()>(
            ATLAS_ID,
            "set_service",
            &service("treasury", SERVICE_ID),
            POINT_LIMIT,
        )
        .expect("current guardian is unaffected");
    session
        .call::<(), ()>(ATLAS_ID, "cancel_pending", &(), POINT_LIMIT)
        .expect("cancel the stuck change");
    assert!(!pending_accepted(session));
    // A cancelled change cannot be accepted later.
    assert_panics(
        accept(session, &typo).expect_err("accept after cancel"),
        "no pending change",
    );
}

#[test]
fn acceptance_applies_when_the_delay_has_passed_and_only_for_guardian_changes() {
    let rng = &mut StdRng::seed_from_u64(26);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let (_, next) = keypair(rng);
    let session = &mut deploy(&owner);
    init(session, &owner, Account::External(op), 5);

    // A delay change is not a guardian change: there is nothing to accept.
    set_height(session, 0);
    set_sender(session, Some(&op));
    session
        .call::<u64, ()>(ATLAS_ID, "set_timelock", &9u64, POINT_LIMIT)
        .expect("schedule delay change");
    assert_panics(
        accept(session, &next).expect_err("accept a delay change"),
        "the pending change is not a guardian change",
    );
    assert!(!pending_accepted(session));
    set_height(session, 5);
    set_sender(session, None);
    session
        .call::<(), ()>(ATLAS_ID, "execute_pending", &(), POINT_LIMIT)
        .expect("a delay change needs no acceptance");

    // Accepting after the (now 9-block) delay applies the change in that call.
    set_height(session, 10);
    set_sender(session, Some(&op));
    session
        .call::<Account, ()>(
            ATLAS_ID,
            "set_guardian",
            &Account::External(next),
            POINT_LIMIT,
        )
        .expect("schedule guardian change");
    set_height(session, 19);
    accept(session, &next).expect("accept once the delay has passed");
    assert_eq!(guardian_of(session), Some(Account::External(next)));
}

// --- Direct-call check against `contract_to_contract` relays -----------------
//
// The genesis transfer contract's `contract_to_contract` lets any contract make
// the transfer contract call another contract inside a transaction a key
// signed. At the callee, `caller` is the transfer contract and `public_sender`
// is the signer, exactly as on a direct Moonlight call; only the call stack
// differs (transfer → contract → transfer → Atlas). The test proxy's `relay`,
// deployed at the transfer contract id and at PROXY_ID, rebuilds that stack.

fn archive<T>(value: &T) -> Vec<u8>
where
    T: rkyv::Serialize<rkyv::ser::serializers::AllocSerializer<1024>>,
{
    rkyv::to_bytes::<_, 1024>(value)
        .expect("archive")
        .into_vec()
}

/// Deploy the test proxy at the transfer contract id, so `relay` there is a
/// transfer-like contract that calls on.
fn deploy_transfer_relay(session: &mut Session, owner: &BlsPublicKey) {
    let _: (ContractId, Option<CallReceipt<()>>) = session
        .deploy(
            PROXY_BYTECODE,
            ContractData::builder()
                .owner(owner.to_bytes().to_vec())
                .contract_id(TRANSFER_CONTRACT),
            POINT_LIMIT,
        )
        .expect("deploy proxy at the transfer contract id");
}

/// A direct Moonlight call: transfer contract → Atlas.
fn via_transfer(
    session: &mut Session,
    fn_name: &str,
    data: Vec<u8>,
) -> Result<CallReceipt<Vec<u8>>, dusk_vm::Error> {
    session.call::<(ContractId, String, Vec<u8>), Vec<u8>>(
        TRANSFER_CONTRACT,
        "relay",
        &(ATLAS_ID, String::from(fn_name), data),
        POINT_LIMIT,
    )
}

/// The `contract_to_contract` shape: transfer → PROXY_ID → transfer → Atlas.
fn via_contract_to_contract(
    session: &mut Session,
    fn_name: &str,
    data: Vec<u8>,
) -> Result<CallReceipt<Vec<u8>>, dusk_vm::Error> {
    let inner = archive(&(ATLAS_ID, String::from(fn_name), data));
    let middle = archive(&(TRANSFER_CONTRACT, String::from("relay"), inner));
    session.call::<(ContractId, String, Vec<u8>), Vec<u8>>(
        TRANSFER_CONTRACT,
        "relay",
        &(PROXY_ID, String::from("relay"), middle),
        POINT_LIMIT,
    )
}

fn pending_of(session: &mut Session) -> Option<PendingView> {
    session
        .call::<(), Option<PendingView>>(ATLAS_ID, "pending", &(), POINT_LIMIT)
        .expect("pending")
        .data
}

#[test]
fn external_guardian_refuses_contract_to_contract_relay() {
    let rng = &mut StdRng::seed_from_u64(60);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let session = &mut deploy(&owner);
    deploy_transfer_relay(session, &owner);
    init(session, &owner, Account::External(op), 5);

    set_sender(session, Some(&op));
    session
        .call::<u64, ()>(ATLAS_ID, "set_timelock", &10u64, POINT_LIMIT)
        .expect("schedule a delay change");
    assert!(pending_of(session).is_some());

    // Same signer, same `caller` (the transfer contract), but a contract in
    // between: refused for every guardian method, the argument-free ones too.
    let relayed = via_contract_to_contract(session, "cancel_pending", archive(&()));
    assert_panics(
        relayed.expect_err("relayed cancel_pending"),
        "External guardian: direct call required",
    );
    let relayed = via_contract_to_contract(
        session,
        "set_service",
        archive(&service("treasury", SERVICE_ID)),
    );
    assert_panics(
        relayed.expect_err("relayed set_service"),
        "External guardian: direct call required",
    );
    assert!(pending_of(session).is_some(), "the pending change survives");

    // The direct Moonlight shape (one transfer-contract frame) still works.
    via_transfer(
        session,
        "set_service",
        archive(&service("treasury", SERVICE_ID)),
    )
    .expect("set_service through the transfer contract");
    via_transfer(session, "cancel_pending", archive(&()))
        .expect("cancel_pending through the transfer contract");
    assert!(pending_of(session).is_none());

    // set_timelock with the pending slot empty and a value under the cap, so
    // the relay check is the only reason it can fail.
    let relayed = via_contract_to_contract(session, "set_timelock", archive(&7u64));
    assert_panics(
        relayed.expect_err("relayed set_timelock"),
        "External guardian: direct call required",
    );
    assert!(pending_of(session).is_none(), "nothing was scheduled");
    via_transfer(session, "set_timelock", archive(&7u64))
        .expect("set_timelock through the transfer contract");
    assert!(pending_of(session).is_some(), "the direct call schedules");
}

#[test]
fn incoming_external_guardian_refuses_relayed_accept() {
    let rng = &mut StdRng::seed_from_u64(61);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let (_, next) = keypair(rng);
    let session = &mut deploy(&owner);
    deploy_transfer_relay(session, &owner);
    init(session, &owner, Account::External(op), 0);

    set_sender(session, Some(&op));
    session
        .call::<Account, ()>(
            ATLAS_ID,
            "set_guardian",
            &Account::External(next),
            POINT_LIMIT,
        )
        .expect("schedule");

    set_sender(session, Some(&next));
    let relayed = via_contract_to_contract(session, "accept_guardian", archive(&()));
    assert_panics(
        relayed.expect_err("relayed accept"),
        "External incoming guardian: direct call required",
    );
    assert!(!pending_accepted(session));
    assert_eq!(guardian_of(session), Some(Account::External(op)));

    let accepted = via_transfer(session, "accept_guardian", archive(&())).expect("direct accept");
    let topics: Vec<&str> = accepted
        .events
        .iter()
        .filter(|e| e.source == ATLAS_ID)
        .map(|e| e.topic.as_str())
        .collect();
    assert_eq!(topics, ["guardian_accepted", "guardian_set"]);
    let ev = decode_event::<GuardianAccepted>(event(&accepted, "guardian_accepted"));
    assert_eq!(ev.guardian, Account::External(next));
    assert_eq!(ev.execute_at, 0);
    assert_eq!(guardian_of(session), Some(Account::External(next)));
}

#[test]
fn deploy_owner_refuses_relayed_init() {
    let rng = &mut StdRng::seed_from_u64(62);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let session = &mut deploy(&owner);
    deploy_transfer_relay(session, &owner);

    set_sender(session, Some(&owner));
    let args = InitArgs {
        guardian: Account::External(op),
        timelock_blocks: 0,
    };
    let relayed = via_contract_to_contract(session, "init_guardian", archive(&args));
    assert_panics(
        relayed.expect_err("relayed init"),
        "Only the deploy owner may init_guardian",
    );
    assert_eq!(guardian_of(session), None);

    via_transfer(session, "init_guardian", archive(&args)).expect("direct init");
    assert_eq!(guardian_of(session), Some(Account::External(op)));
}

#[test]
fn contract_guardian_is_unaffected_by_call_depth() {
    let rng = &mut StdRng::seed_from_u64(63);
    let (_, owner) = keypair(rng);
    let session = &mut deploy(&owner);
    deploy_transfer_relay(session, &owner);
    init(session, &owner, Account::Contract(PROXY_ID), 0);

    // transfer → PROXY_ID → Atlas: `caller` is the guardian contract, two
    // frames deep. A contract guardian is matched on `caller` alone.
    session
        .call::<(ContractId, String, Vec<u8>), Vec<u8>>(
            TRANSFER_CONTRACT,
            "relay",
            &(
                PROXY_ID,
                String::from("call_set_service"),
                archive(&(ATLAS_ID, String::from("treasury"), SERVICE_ID)),
            ),
            POINT_LIMIT,
        )
        .expect("contract guardian through the transfer contract");
    let resolved = session
        .call::<String, Option<ContractId>>(
            ATLAS_ID,
            "resolve",
            &String::from("treasury"),
            POINT_LIMIT,
        )
        .unwrap()
        .data;
    assert_eq!(resolved, Some(SERVICE_ID));
}
