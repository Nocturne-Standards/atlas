//! Same Atlas id. External guardian rotates to the knot-proposals contract,
//! then proposals `call_raw` into Atlas `set_service`. Guardian schedule/cancel
//! stays on that same id.

extern crate alloc;

use alloc::string::String;
use alloc::vec::Vec;

use dusk_bytes::Serializable;
use dusk_core::abi::{ContractId, Metadata};
use dusk_core::signatures::bls::{PublicKey as BlsPublicKey, SecretKey as BlsSecretKey};
use dusk_vm::{CallReceipt, ContractData, Session, VM};
use rand::SeedableRng;
use rand::rngs::StdRng;
use rkyv::Serialize;
use rkyv::ser::Serializer;
use rkyv::ser::serializers::AllocSerializer;

use atlas_encoding::call_types::{Account, InitArgs, PendingView, SetServiceArgs};

use knot_encoding::call_types::{
    ApproveArgs, CreateAccountArgs, ProposalStatus, ProposalView, ProposeArgs,
};

const ATLAS_BYTECODE: &[u8] =
    include_bytes!("../../../target/contract/wasm32-unknown-unknown/release/atlas.wasm");
/// Built by `make knot-wasm` (clone of Nocturne-Standards/knot @ KNOT_REV under target/knot-src).
const PROPOSALS_BYTECODE: &[u8] = include_bytes!(
    "../../../target/knot-src/target/contract/wasm32-unknown-unknown/release/knot_proposals.wasm"
);
const REGISTRY_BYTECODE: &[u8] = include_bytes!(
    "../../../target/knot-src/target/contract/wasm32-unknown-unknown/release/knot_registry.wasm"
);
// Knot keeps its state in separate data contracts; each logic contract is
// pointed at its book with `init_data` before first use.
const PROPOSALS_DATA_BYTECODE: &[u8] = include_bytes!(
    "../../../target/knot-src/target/contract/wasm32-unknown-unknown/release/knot_proposals_data.wasm"
);
const REGISTRY_DATA_BYTECODE: &[u8] = include_bytes!(
    "../../../target/knot-src/target/contract/wasm32-unknown-unknown/release/knot_registry_data.wasm"
);

/// Fixed for the whole suite — tests never redeploy Atlas under a new id.
const ATLAS_ID: ContractId = ContractId::from_bytes([0xa7; 32]);
const PROPOSALS_ID: ContractId = ContractId::from_bytes([0xb2; 32]);
const REGISTRY_ID: ContractId = ContractId::from_bytes([0xa1; 32]);
const REGISTRY_DATA_ID: ContractId = ContractId::from_bytes([0xa2; 32]);
const PROPOSALS_DATA_ID: ContractId = ContractId::from_bytes([0xb5; 32]);
const SERVICE_LOGIC_A: ContractId = ContractId::from_bytes([0x11; 32]);
const SERVICE_LOGIC_B: ContractId = ContractId::from_bytes([0x22; 32]);

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

fn rkyv_bytes<T>(value: &T) -> Vec<u8>
where
    T: Serialize<AllocSerializer<256>>,
{
    let mut ser = AllocSerializer::<256>::default();
    ser.serialize_value(value).expect("rkyv serialize");
    ser.into_serializer().into_inner().to_vec()
}

/// Deploy Atlas + registry + proposals once. Atlas id stays `ATLAS_ID`.
fn deploy_stack(owner_pk: &BlsPublicKey) -> Session {
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

    for (bytecode, id) in [
        (REGISTRY_DATA_BYTECODE, REGISTRY_DATA_ID),
        (PROPOSALS_DATA_BYTECODE, PROPOSALS_DATA_ID),
    ] {
        let _: (ContractId, Option<CallReceipt<()>>) = session
            .deploy(
                bytecode,
                ContractData::builder()
                    .owner(owner_pk.to_bytes().to_vec())
                    .contract_id(id),
                POINT_LIMIT,
            )
            .expect("deploy data contract");
    }

    let _: (ContractId, Option<CallReceipt<()>>) = session
        .deploy(
            REGISTRY_BYTECODE,
            ContractData::builder()
                .owner(owner_pk.to_bytes().to_vec())
                .contract_id(REGISTRY_ID),
            POINT_LIMIT,
        )
        .expect("deploy registry");

    let _: (ContractId, Option<CallReceipt<()>>) = session
        .deploy(
            PROPOSALS_BYTECODE,
            ContractData::builder()
                .owner(owner_pk.to_bytes().to_vec())
                .contract_id(PROPOSALS_ID),
            POINT_LIMIT,
        )
        .expect("deploy proposals");

    // genesis_session stores the height as an untyped 0 (4 bytes). Contracts
    // read a u64, and uplink 0.21 rejects the short value.
    session
        .set_meta(Metadata::BLOCK_HEIGHT, 0u64)
        .expect("setting block_height metadata should succeed");
    session
}

fn bootstrap(session: &mut Session, owner: &BlsPublicKey, operator: &BlsPublicKey) {
    set_sender(session, Some(owner));
    session
        .call::<InitArgs, ()>(
            ATLAS_ID,
            "init_guardian",
            &InitArgs {
                guardian: Account::External(*operator),
                timelock_blocks: 0,
            },
            POINT_LIMIT,
        )
        .expect("init_guardian");

    // The knot data contracts resolve their logic contract through Atlas, so
    // both names must be registered before init_registry / init_data.
    set_sender(session, Some(operator));
    for (name, id) in [
        ("knot-registry", REGISTRY_ID),
        ("knot-proposals", PROPOSALS_ID),
    ] {
        session
            .call::<SetServiceArgs, ()>(
                ATLAS_ID,
                "set_service",
                &SetServiceArgs {
                    name: String::from(name),
                    id,
                },
                POINT_LIMIT,
            )
            .expect("register knot service");
    }
    set_sender(session, Some(owner));

    session
        .call::<ContractId, ()>(REGISTRY_ID, "init_data", &REGISTRY_DATA_ID, POINT_LIMIT)
        .expect("registry init_data");
    session
        .call::<ContractId, ()>(PROPOSALS_ID, "init_data", &PROPOSALS_DATA_ID, POINT_LIMIT)
        .expect("proposals init_data");
    session
        .call::<ContractId, ()>(PROPOSALS_ID, "init_registry", &REGISTRY_ID, POINT_LIMIT)
        .expect("proposals init_registry");
    session
        .call::<bool, ()>(PROPOSALS_ID, "set_tombstone", &false, POINT_LIMIT)
        .expect("set_tombstone");
    set_sender(session, None);
}

/// Creates the account and authorizes it on proposals; knot-proposals refuses
/// proposals for any other registry account.
fn create_account(
    session: &mut Session,
    owner: &BlsPublicKey,
    members: Vec<BlsPublicKey>,
    threshold: u32,
) -> u64 {
    let id = session
        .call::<CreateAccountArgs, u64>(
            REGISTRY_ID,
            "create_account",
            &CreateAccountArgs { members, threshold },
            POINT_LIMIT,
        )
        .expect("create_account")
        .data;
    set_sender(session, Some(owner));
    session
        .call::<u64, ()>(PROPOSALS_ID, "set_authorized_account", &id, POINT_LIMIT)
        .expect("set_authorized_account");
    set_sender(session, None);
    id
}

fn approve(
    session: &mut Session,
    proposal_id: u64,
    sk: &BlsSecretKey,
    pk: &BlsPublicKey,
    digest: &[u8; 32],
) {
    let args = ApproveArgs {
        proposal_id,
        signer: *pk,
        // PreforkHostQuery: VM::ephemeral PreFork host query. Production code uses only sign/verify/sign_multisig/aggregate; *_insecure is allowed only on allowlisted test paths with a PreforkHostQuery justification.
        signature: sk.sign_insecure(digest),
    };
    session
        .call::<ApproveArgs, ()>(PROPOSALS_ID, "approve", &args, POINT_LIMIT)
        .expect("approve");
}

#[test]
fn guardian_rotation_timelock_schedule_and_cancel() {
    let rng = &mut StdRng::seed_from_u64(40);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let session = &mut deploy_stack(&owner);
    bootstrap(session, &owner, &op);

    set_sender(session, Some(&op));
    session
        .call::<u64, ()>(ATLAS_ID, "set_timelock", &5u64, POINT_LIMIT)
        .expect("set_timelock");

    session
        .call::<Account, ()>(
            ATLAS_ID,
            "set_guardian",
            &Account::Contract(PROPOSALS_ID),
            POINT_LIMIT,
        )
        .expect("schedule set_guardian");

    let pending = session
        .call::<(), Option<PendingView>>(ATLAS_ID, "pending", &(), POINT_LIMIT)
        .unwrap()
        .data
        .expect("pending guardian");
    assert!(pending.execute_at > 0);

    assert!(
        session
            .call::<(), ()>(ATLAS_ID, "execute_pending", &(), POINT_LIMIT)
            .is_err(),
        "too early to execute"
    );
    session
        .call::<(), ()>(ATLAS_ID, "cancel_pending", &(), POINT_LIMIT)
        .expect("cancel guardian rotation");
    assert!(
        session
            .call::<(), Option<PendingView>>(ATLAS_ID, "pending", &(), POINT_LIMIT)
            .unwrap()
            .data
            .is_none()
    );

    let guardian = session
        .call::<(), Option<Account>>(ATLAS_ID, "guardian", &(), POINT_LIMIT)
        .unwrap()
        .data;
    assert_eq!(guardian, Some(Account::External(op)));
}

/// Propose `function_name` on `target` through the proposals contract, collect
/// two approvals, finalize, and return the proposal id.
#[allow(clippy::too_many_arguments)]
fn run_proposal(
    session: &mut Session,
    account_id: u64,
    function_name: &str,
    call_args: Vec<u8>,
    nonce: u64,
    signers: [(&BlsSecretKey, &BlsPublicKey); 2],
) -> u64 {
    let propose = ProposeArgs {
        registry_account_id: account_id,
        target: ATLAS_ID,
        function_name: String::from(function_name),
        call_args,
        nonce,
        deadline: 1000,
    };
    let proposal_id = session
        .call::<ProposeArgs, u64>(PROPOSALS_ID, "propose", &propose, POINT_LIMIT)
        .expect("propose")
        .data;
    let digest = session
        .call::<u64, Option<ProposalView>>(PROPOSALS_ID, "proposal", &proposal_id, POINT_LIMIT)
        .unwrap()
        .data
        .expect("view")
        .signed_digest;
    for (sk, pk) in signers {
        approve(session, proposal_id, sk, pk, &digest);
    }
    session
        .call::<u64, ()>(PROPOSALS_ID, "finalize", &proposal_id, POINT_LIMIT)
        .unwrap_or_else(|e| panic!("finalize {function_name}: {e:?}"));
    proposal_id
}

#[test]
fn proposals_call_raw_set_service_same_atlas_id() {
    let rng = &mut StdRng::seed_from_u64(41);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let (sk1, pk1) = keypair(rng);
    let (sk2, pk2) = keypair(rng);
    let (_sk3, pk3) = keypair(rng);

    let session = &mut deploy_stack(&owner);
    bootstrap(session, &owner, &op);

    set_sender(session, Some(&op));
    session
        .call::<Account, ()>(
            ATLAS_ID,
            "set_guardian",
            &Account::Contract(PROPOSALS_ID),
            POINT_LIMIT,
        )
        .expect("rotate guardian to proposals");

    // Scheduled, not applied: the proposals contract has to accept, and it can
    // only act through a finalized proposal.
    let account_id = create_account(session, &owner, alloc::vec![pk1, pk2, pk3], 2);
    assert_eq!(
        session
            .call::<(), Option<Account>>(ATLAS_ID, "guardian", &(), POINT_LIMIT)
            .unwrap()
            .data,
        Some(Account::External(op))
    );
    run_proposal(
        session,
        account_id,
        "accept_guardian",
        rkyv_bytes(&()),
        1,
        [(&sk1, &pk1), (&sk2, &pk2)],
    );

    set_sender(session, Some(&op));
    let denied = session.call::<SetServiceArgs, ()>(
        ATLAS_ID,
        "set_service",
        &SetServiceArgs {
            name: String::from("treasury"),
            id: SERVICE_LOGIC_A,
        },
        POINT_LIMIT,
    );
    assert!(
        denied.is_err(),
        "external key must not mutate once the guardian is the proposals contract"
    );
    set_sender(session, None);

    let call_args = rkyv_bytes(&SetServiceArgs {
        name: String::from("treasury"),
        id: SERVICE_LOGIC_B,
    });
    let proposal_id = run_proposal(
        session,
        account_id,
        "set_service",
        call_args,
        2,
        [(&sk1, &pk1), (&sk2, &pk2)],
    );

    let status = session
        .call::<u64, Option<ProposalStatus>>(PROPOSALS_ID, "status", &proposal_id, POINT_LIMIT)
        .unwrap()
        .data
        .expect("status");
    assert_eq!(status, ProposalStatus::Executed);

    let resolved = session
        .call::<String, Option<ContractId>>(
            ATLAS_ID,
            "resolve",
            &String::from("treasury"),
            POINT_LIMIT,
        )
        .unwrap()
        .data;
    assert_eq!(resolved, Some(SERVICE_LOGIC_B));

    let guardian = session
        .call::<(), Option<Account>>(ATLAS_ID, "guardian", &(), POINT_LIMIT)
        .unwrap()
        .data;
    assert_eq!(guardian, Some(Account::Contract(PROPOSALS_ID)));
}

#[test]
fn cancelled_guardian_rotation_leaves_service_write_in_place() {
    let rng = &mut StdRng::seed_from_u64(42);
    let (_, owner) = keypair(rng);
    let (_, op) = keypair(rng);
    let session = &mut deploy_stack(&owner);
    bootstrap(session, &owner, &op);

    set_sender(session, Some(&op));
    session
        .call::<u64, ()>(ATLAS_ID, "set_timelock", &3u64, POINT_LIMIT)
        .expect("set_timelock");
    session
        .call::<SetServiceArgs, ()>(
            ATLAS_ID,
            "set_service",
            &SetServiceArgs {
                name: String::from("treasury"),
                id: SERVICE_LOGIC_A,
            },
            POINT_LIMIT,
        )
        .expect("set_service");
    session
        .call::<Account, ()>(
            ATLAS_ID,
            "set_guardian",
            &Account::Contract(PROPOSALS_ID),
            POINT_LIMIT,
        )
        .expect("schedule set_guardian");

    assert!(
        session
            .call::<(), ()>(ATLAS_ID, "execute_pending", &(), POINT_LIMIT)
            .is_err()
    );
    session
        .call::<(), ()>(ATLAS_ID, "cancel_pending", &(), POINT_LIMIT)
        .expect("cancel guardian rotation");

    let guardian = session
        .call::<(), Option<Account>>(ATLAS_ID, "guardian", &(), POINT_LIMIT)
        .unwrap()
        .data;
    assert_eq!(guardian, Some(Account::External(op)));

    let resolved = session
        .call::<String, Option<ContractId>>(
            ATLAS_ID,
            "resolve",
            &String::from("treasury"),
            POINT_LIMIT,
        )
        .unwrap()
        .data;
    assert_eq!(resolved, Some(SERVICE_LOGIC_A));
}
