//! Consumer-local archived-layout goldens for `atlas` call types and events.
//!
//! **rkyv camp:** this crate pins `rkyv = "=0.7.46"` (goldens marked 0.7.39 were
//! produced before the bump and are byte-identical).
//!
//! Struct Archive types carry `#[archive_attr(repr(C))]`. Data-carrying enums
//! `Account` / `PendingChange` skip the attribute — rustc rejects it on
//! archived enums. Pin is the golden.
//!
//! Fixed inputs: `StdRng::seed_from_u64(0xa11ce_u64)`; service `ContractId`
//! all `0x0d`; name `"treasury-data"`; delay `86400`; `execute_at: 100`.
//!
//! v0.3.0 replaced `GovMode`, roles, and `u64` constants. `SetServiceArgs`,
//! `ServiceUpdated`, and `TimelockSet` kept their v0.2.0 bytes.

extern crate alloc;

use alloc::format;
use alloc::string::String;

use dusk_core::abi::ContractId;
use dusk_core::signatures::bls::{PublicKey as BlsPublicKey, SecretKey as BlsSecretKey};
use rand::SeedableRng;
use rand::rngs::StdRng;
use rkyv::Serialize;
use rkyv::ser::serializers::AllocSerializer;

use atlas_encoding::call_types::{Account, InitArgs, PendingChange, PendingView, SetServiceArgs};
use atlas_encoding::events::{
    GuardianAccepted, GuardianSet, PendingCancelled, PendingScheduled, ServiceUpdated, TimelockSet,
};

const SERVICE_ID: ContractId = ContractId::from_bytes([0x0d; 32]);

fn archive_hex<T>(v: &T) -> String
where
    T: Serialize<AllocSerializer<4096>>,
{
    rkyv::to_bytes::<_, 4096>(v)
        .expect("archive")
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn fixed_keys() -> [(BlsSecretKey, BlsPublicKey); 2] {
    let mut rng = StdRng::seed_from_u64(0xa11ce_u64);
    std::array::from_fn(|_| {
        let sk = BlsSecretKey::random(&mut rng);
        let pk = BlsPublicKey::from(&sk);
        (sk, pk)
    })
}

fn pk0() -> BlsPublicKey {
    fixed_keys()[0].1
}

/// `Account::External(pk0)`.
/// Provenance: rustc 1.94.0; rkyv 0.7.39.
pub const GOLDEN_ACCOUNT_EXTERNAL_HEX: &str = "0000000000000000e3a945bd7dbd51365c255b3a7851432419f20ddb7bc948f5b60d677c5b02ff9e6255228ee75c9dd8a3bd4a86751e9b14cf501c89e69b4b2a2169c189accff3afc07b7ff80a0acfc75a4e073ee006624f722dd52ef90ae1828d8bfdcb6c1e260aad4c44e90e1b5e5c2067d4363ee978a0db41fdba0f29829a1263e43f33f231a9dc20fc5acafc235d9c920f2772cbd716ddb84cca39704625b55a01a011e7eeae177ef0949bce380f2d64afd6038e15ff70e7aaf4d9b92e8bf4188696e1264e090000000000000000";

/// `Account::Contract(SERVICE_ID)`.
/// Provenance: rustc 1.94.0; rkyv 0.7.39.
pub const GOLDEN_ACCOUNT_CONTRACT_HEX: &str = "010d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

/// `InitArgs { guardian: External(pk0), timelock_blocks: 86400 }`.
/// Provenance: rustc 1.94.0; rkyv 0.7.39; post-`repr(C)`.
pub const GOLDEN_INIT_ARGS_HEX: &str = "0000000000000000e3a945bd7dbd51365c255b3a7851432419f20ddb7bc948f5b60d677c5b02ff9e6255228ee75c9dd8a3bd4a86751e9b14cf501c89e69b4b2a2169c189accff3afc07b7ff80a0acfc75a4e073ee006624f722dd52ef90ae1828d8bfdcb6c1e260aad4c44e90e1b5e5c2067d4363ee978a0db41fdba0f29829a1263e43f33f231a9dc20fc5acafc235d9c920f2772cbd716ddb84cca39704625b55a01a011e7eeae177ef0949bce380f2d64afd6038e15ff70e7aaf4d9b92e8bf4188696e1264e0900000000000000008051010000000000";

/// `SetServiceArgs { name: "treasury-data", id: SERVICE_ID }`.
/// Provenance: rustc 1.94.0 (4a4ef493e 2026-03-02); rkyv 0.7.39; post-`repr(C)`.
/// Unchanged from v0.2.0.
pub const GOLDEN_SET_SERVICE_ARGS_HEX: &str = "74726561737572792d646174610000000d000000f0ffffff0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d";

/// `PendingChange::Guardian(Account::External(pk0))`.
/// Provenance: rustc 1.94.0; rkyv 0.7.39.
pub const GOLDEN_PENDING_GUARDIAN_EXTERNAL_HEX: &str = "00000000000000000000000000000000e3a945bd7dbd51365c255b3a7851432419f20ddb7bc948f5b60d677c5b02ff9e6255228ee75c9dd8a3bd4a86751e9b14cf501c89e69b4b2a2169c189accff3afc07b7ff80a0acfc75a4e073ee006624f722dd52ef90ae1828d8bfdcb6c1e260aad4c44e90e1b5e5c2067d4363ee978a0db41fdba0f29829a1263e43f33f231a9dc20fc5acafc235d9c920f2772cbd716ddb84cca39704625b55a01a011e7eeae177ef0949bce380f2d64afd6038e15ff70e7aaf4d9b92e8bf4188696e1264e090000000000000000";

/// `PendingChange::Guardian(Account::Contract(SERVICE_ID))`.
/// Provenance: rustc 1.94.0; rkyv 0.7.39.
pub const GOLDEN_PENDING_GUARDIAN_CONTRACT_HEX: &str = "0000000000000000010d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

/// `PendingChange::Timelock(86400)`.
/// Provenance: rustc 1.94.0; rkyv 0.7.39.
pub const GOLDEN_PENDING_TIMELOCK_HEX: &str = "010000000000000080510100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

/// `PendingView { change: Guardian(Contract(SERVICE_ID)), execute_at: 100 }`.
/// Provenance: rustc 1.94.0; rkyv 0.7.39; post-`repr(C)`.
pub const GOLDEN_PENDING_VIEW_GUARDIAN_HEX: &str = "0000000000000000010d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006400000000000000";

/// `PendingView { change: Timelock(86400), execute_at: 100 }`.
/// Provenance: rustc 1.94.0; rkyv 0.7.39; post-`repr(C)`.
pub const GOLDEN_PENDING_VIEW_TIMELOCK_HEX: &str = "0100000000000000805101000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006400000000000000";

/// `GuardianSet { guardian: External(pk0) }`.
/// Provenance: rustc 1.94.0; rkyv 0.7.39; post-`repr(C)`.
pub const GOLDEN_EVENT_GUARDIAN_SET_HEX: &str = "0000000000000000e3a945bd7dbd51365c255b3a7851432419f20ddb7bc948f5b60d677c5b02ff9e6255228ee75c9dd8a3bd4a86751e9b14cf501c89e69b4b2a2169c189accff3afc07b7ff80a0acfc75a4e073ee006624f722dd52ef90ae1828d8bfdcb6c1e260aad4c44e90e1b5e5c2067d4363ee978a0db41fdba0f29829a1263e43f33f231a9dc20fc5acafc235d9c920f2772cbd716ddb84cca39704625b55a01a011e7eeae177ef0949bce380f2d64afd6038e15ff70e7aaf4d9b92e8bf4188696e1264e090000000000000000";

/// `GuardianAccepted { guardian: Contract(SERVICE_ID), execute_at: 100 }`.
/// Provenance: rustc 1.94.0; rkyv 0.7.46; post-`repr(C)`. New in 0.4.0.
pub const GOLDEN_EVENT_GUARDIAN_ACCEPTED_CONTRACT_HEX: &str = "010d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006400000000000000";

/// `GuardianAccepted { guardian: External(pk0), execute_at: 100 }`.
/// Provenance: rustc 1.94.0; rkyv 0.7.46; post-`repr(C)`. New in 0.4.0.
pub const GOLDEN_EVENT_GUARDIAN_ACCEPTED_EXTERNAL_HEX: &str = "0000000000000000e3a945bd7dbd51365c255b3a7851432419f20ddb7bc948f5b60d677c5b02ff9e6255228ee75c9dd8a3bd4a86751e9b14cf501c89e69b4b2a2169c189accff3afc07b7ff80a0acfc75a4e073ee006624f722dd52ef90ae1828d8bfdcb6c1e260aad4c44e90e1b5e5c2067d4363ee978a0db41fdba0f29829a1263e43f33f231a9dc20fc5acafc235d9c920f2772cbd716ddb84cca39704625b55a01a011e7eeae177ef0949bce380f2d64afd6038e15ff70e7aaf4d9b92e8bf4188696e1264e0900000000000000006400000000000000";

/// `ServiceUpdated { name: "treasury-data", id: SERVICE_ID }`.
/// Provenance: rustc 1.94.0 (4a4ef493e 2026-03-02); rkyv 0.7.39.
/// Unchanged from v0.2.0.
pub const GOLDEN_EVENT_SERVICE_UPDATED_HEX: &str = "74726561737572792d646174610000000d000000f0ffffff0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d";

/// `TimelockSet { blocks: 86400 }`.
/// Provenance: rustc 1.94.0 (4a4ef493e 2026-03-02); rkyv 0.7.39.
/// Unchanged from v0.2.0.
pub const GOLDEN_EVENT_TIMELOCK_SET_HEX: &str = "8051010000000000";

/// `PendingScheduled { change: Timelock(86400), execute_at: 100 }`.
/// Provenance: rustc 1.94.0; rkyv 0.7.39; post-`repr(C)`.
pub const GOLDEN_EVENT_PENDING_SCHEDULED_HEX: &str = "0100000000000000805101000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006400000000000000";

/// `PendingCancelled { change: Timelock(86400), execute_at: 100 }`.
/// Provenance: rustc 1.94.0; rkyv 0.7.46; post-`repr(C)`.
/// `execute_at` added in encoding 0.5.0. Same field order as `PendingScheduled`.
pub const GOLDEN_EVENT_PENDING_CANCELLED_HEX: &str = "0100000000000000805101000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006400000000000000";

#[test]
fn account_external_golden() {
    assert_eq!(
        archive_hex(&Account::External(pk0())),
        GOLDEN_ACCOUNT_EXTERNAL_HEX
    );
}

#[test]
fn account_contract_golden() {
    assert_eq!(
        archive_hex(&Account::Contract(SERVICE_ID)),
        GOLDEN_ACCOUNT_CONTRACT_HEX
    );
}

#[test]
fn init_args_golden() {
    let args = InitArgs {
        guardian: Account::External(pk0()),
        timelock_blocks: 86400,
    };
    assert_eq!(archive_hex(&args), GOLDEN_INIT_ARGS_HEX);
}

#[test]
fn set_service_args_golden() {
    let args = SetServiceArgs {
        name: String::from("treasury-data"),
        id: SERVICE_ID,
    };
    assert_eq!(archive_hex(&args), GOLDEN_SET_SERVICE_ARGS_HEX);
}

#[test]
fn pending_guardian_external_golden() {
    let change = PendingChange::Guardian(Account::External(pk0()));
    assert_eq!(archive_hex(&change), GOLDEN_PENDING_GUARDIAN_EXTERNAL_HEX);
}

#[test]
fn pending_guardian_contract_golden() {
    let change = PendingChange::Guardian(Account::Contract(SERVICE_ID));
    assert_eq!(archive_hex(&change), GOLDEN_PENDING_GUARDIAN_CONTRACT_HEX);
}

#[test]
fn pending_timelock_golden() {
    assert_eq!(
        archive_hex(&PendingChange::Timelock(86400)),
        GOLDEN_PENDING_TIMELOCK_HEX
    );
}

#[test]
fn pending_view_guardian_golden() {
    let view = PendingView {
        change: PendingChange::Guardian(Account::Contract(SERVICE_ID)),
        execute_at: 100,
    };
    assert_eq!(archive_hex(&view), GOLDEN_PENDING_VIEW_GUARDIAN_HEX);
}

#[test]
fn pending_view_timelock_golden() {
    let view = PendingView {
        change: PendingChange::Timelock(86400),
        execute_at: 100,
    };
    assert_eq!(archive_hex(&view), GOLDEN_PENDING_VIEW_TIMELOCK_HEX);
}

#[test]
fn event_guardian_set_golden() {
    let ev = GuardianSet {
        guardian: Account::External(pk0()),
    };
    assert_eq!(archive_hex(&ev), GOLDEN_EVENT_GUARDIAN_SET_HEX);
}

#[test]
fn event_guardian_accepted_golden() {
    let contract = GuardianAccepted {
        guardian: Account::Contract(SERVICE_ID),
        execute_at: 100,
    };
    assert_eq!(
        archive_hex(&contract),
        GOLDEN_EVENT_GUARDIAN_ACCEPTED_CONTRACT_HEX
    );
    let external = GuardianAccepted {
        guardian: Account::External(pk0()),
        execute_at: 100,
    };
    assert_eq!(
        archive_hex(&external),
        GOLDEN_EVENT_GUARDIAN_ACCEPTED_EXTERNAL_HEX
    );
}

#[test]
fn event_service_updated_golden() {
    let ev = ServiceUpdated {
        name: String::from("treasury-data"),
        id: SERVICE_ID,
    };
    assert_eq!(archive_hex(&ev), GOLDEN_EVENT_SERVICE_UPDATED_HEX);
}

#[test]
fn event_timelock_set_golden() {
    let ev = TimelockSet { blocks: 86400 };
    assert_eq!(archive_hex(&ev), GOLDEN_EVENT_TIMELOCK_SET_HEX);
}

#[test]
fn event_pending_scheduled_golden() {
    let ev = PendingScheduled {
        change: PendingChange::Timelock(86400),
        execute_at: 100,
    };
    assert_eq!(archive_hex(&ev), GOLDEN_EVENT_PENDING_SCHEDULED_HEX);
}

#[test]
fn event_pending_cancelled_golden() {
    let ev = PendingCancelled {
        change: PendingChange::Timelock(86400),
        execute_at: 100,
    };
    assert_eq!(archive_hex(&ev), GOLDEN_EVENT_PENDING_CANCELLED_HEX);
}
