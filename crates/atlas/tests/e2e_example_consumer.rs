//! Atlas consumer example: counter + front door that re-resolves after repoint.
//!
//! Fixed Atlas id for this test (and the baked `ATLAS_PIN_HEX` for the front WASM):
//! `0xa7` repeated 32 times — hex `a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7`.

extern crate alloc;

use alloc::string::String;

use dusk_bytes::Serializable;
use dusk_core::abi::{ContractId, Metadata};
use dusk_core::signatures::bls::{PublicKey as BlsPublicKey, SecretKey as BlsSecretKey};
use dusk_vm::{CallReceipt, ContractData, Session, VM};
use rand::SeedableRng;
use rand::rngs::StdRng;

use atlas_encoding::call_types::{Account, InitArgs, SetServiceArgs};

const ATLAS_BYTECODE: &[u8] =
    include_bytes!("../../../target/contract/wasm32-unknown-unknown/release/atlas.wasm");
const COUNTER_BYTECODE: &[u8] = include_bytes!(
    "../../../target/contract/wasm32-unknown-unknown/release/atlas_example_counter.wasm"
);
const FRONT_BYTECODE: &[u8] = include_bytes!(
    "../../../target/contract/wasm32-unknown-unknown/release/atlas_example_front.wasm"
);

const ATLAS_ID: ContractId = ContractId::from_bytes([0xa7; 32]);
const COUNTER_A_ID: ContractId = ContractId::from_bytes([0x41; 32]);
const COUNTER_B_ID: ContractId = ContractId::from_bytes([0x42; 32]);
const FRONT_ID: ContractId = ContractId::from_bytes([0x43; 32]);

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

fn service(name: &str, id: ContractId) -> SetServiceArgs {
    SetServiceArgs {
        name: String::from(name),
        id,
    }
}

#[test]
fn example_front_door_re_resolves_after_repoint() {
    let rng = &mut StdRng::seed_from_u64(0x_a71c);
    let (_owner_sk, owner_pk) = keypair(rng);
    let (_guardian_sk, guardian_pk) = keypair(rng);

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
    session
        .set_meta(Metadata::BLOCK_HEIGHT, 0u64)
        .expect("block height");

    set_sender(&mut session, Some(&owner_pk));
    session
        .call::<InitArgs, ()>(
            ATLAS_ID,
            "init_guardian",
            &InitArgs {
                guardian: Account::External(guardian_pk),
                timelock_blocks: 30,
            },
            POINT_LIMIT,
        )
        .expect("init_guardian");

    let _: (ContractId, Option<CallReceipt<()>>) = session
        .deploy(
            COUNTER_BYTECODE,
            ContractData::builder()
                .owner(owner_pk.to_bytes().to_vec())
                .contract_id(COUNTER_A_ID),
            POINT_LIMIT,
        )
        .expect("deploy counter A");

    set_sender(&mut session, Some(&guardian_pk));
    session
        .call::<SetServiceArgs, ()>(
            ATLAS_ID,
            "set_service",
            &service("counter", COUNTER_A_ID),
            POINT_LIMIT,
        )
        .expect("set_service counter → A");

    let _: (ContractId, Option<CallReceipt<()>>) = session
        .deploy(
            FRONT_BYTECODE,
            ContractData::builder()
                .owner(owner_pk.to_bytes().to_vec())
                .contract_id(FRONT_ID),
            POINT_LIMIT,
        )
        .expect("deploy front");

    set_sender(&mut session, None);
    session
        .call::<(), ()>(FRONT_ID, "increment", &(), POINT_LIMIT)
        .expect("front increment → A");
    let via_front = session
        .call::<(), u64>(FRONT_ID, "value", &(), POINT_LIMIT)
        .expect("front value")
        .data;
    assert_eq!(
        via_front, 1,
        "front should read counter A after first increment"
    );

    let _: (ContractId, Option<CallReceipt<()>>) = session
        .deploy(
            COUNTER_BYTECODE,
            ContractData::builder()
                .owner(owner_pk.to_bytes().to_vec())
                .contract_id(COUNTER_B_ID),
            POINT_LIMIT,
        )
        .expect("deploy counter B");

    set_sender(&mut session, Some(&guardian_pk));
    session
        .call::<SetServiceArgs, ()>(
            ATLAS_ID,
            "set_service",
            &service("counter", COUNTER_B_ID),
            POINT_LIMIT,
        )
        .expect("set_service counter → B");

    set_sender(&mut session, None);
    session
        .call::<(), ()>(FRONT_ID, "increment", &(), POINT_LIMIT)
        .expect("front increment → B");

    let b = session
        .call::<(), u64>(COUNTER_B_ID, "value", &(), POINT_LIMIT)
        .expect("counter B value")
        .data;
    let a = session
        .call::<(), u64>(COUNTER_A_ID, "value", &(), POINT_LIMIT)
        .expect("counter A value")
        .data;
    assert_eq!(b, 1, "B incremented once");
    assert_eq!(a, 1, "A unchanged after repoint");
}
