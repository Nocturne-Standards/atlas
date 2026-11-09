//! Named Atlas events decode to JSON. Unknown topics error.
//! Version is the deployment record, not a field inside the bytes.

use atlas_encoding::call_types::{Account, PendingChange};
use atlas_encoding::events::{
    GuardianAccepted, GuardianSet, PendingCancelled, PendingScheduled, ServiceUpdated, TimelockSet,
};
use atlas_event_decoder::{
    ARMS, CONTRACT, DEPLOYMENT_VERSION, DecodeError, GUARDIAN_ACCEPTED_SINCE,
    PENDING_CANCELLED_EXECUTE_AT_SINCE, SUPPORTED_VERSIONS, decode,
};
use dusk_core::abi::ContractId;
use serde::de::DeserializeOwned;

const SERVICE_ID: ContractId = ContractId::from_bytes([0x0d; 32]);

const GUARDIAN_SET_HEX: &str = "0000000000000000e3a945bd7dbd51365c255b3a7851432419f20ddb7bc948f5b60d677c5b02ff9e6255228ee75c9dd8a3bd4a86751e9b14cf501c89e69b4b2a2169c189accff3afc07b7ff80a0acfc75a4e073ee006624f722dd52ef90ae1828d8bfdcb6c1e260aad4c44e90e1b5e5c2067d4363ee978a0db41fdba0f29829a1263e43f33f231a9dc20fc5acafc235d9c920f2772cbd716ddb84cca39704625b55a01a011e7eeae177ef0949bce380f2d64afd6038e15ff70e7aaf4d9b92e8bf4188696e1264e090000000000000000";
const GUARDIAN_ACCEPTED_HEX: &str = "010d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006400000000000000";
const SERVICE_UPDATED_HEX: &str = "74726561737572792d646174610000000d000000f0ffffff0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d";
const TIMELOCK_SET_HEX: &str = "8051010000000000";
const PENDING_SCHEDULED_HEX: &str = "0100000000000000805101000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006400000000000000";
/// atlas 0.5.0 and earlier: `change` only.
const PENDING_CANCELLED_V4_HEX: &str = "010000000000000080510100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
/// atlas 0.6.0: `PendingCancelled { change: Timelock(86400), execute_at: 100 }`.
const PENDING_CANCELLED_V5_HEX: &str = "0100000000000000805101000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006400000000000000";

fn bytes(hex_payload: &str) -> Vec<u8> {
    hex::decode(hex_payload).expect("hex")
}

fn payload_as<T: DeserializeOwned>(topic: &str, hex_payload: &str) -> T {
    let value = decode(CONTRACT, topic, DEPLOYMENT_VERSION, &bytes(hex_payload)).expect(topic);
    assert_eq!(value["contract"], CONTRACT);
    assert_eq!(value["topic"], topic);
    assert_eq!(value["version"], DEPLOYMENT_VERSION);
    serde_json::from_value(value["payload"].clone()).expect("payload json")
}

#[test]
fn arms_are_the_named_atlas_events() {
    assert_eq!(
        ARMS,
        &[
            ("atlas", "guardian_set"),
            ("atlas", "guardian_accepted"),
            ("atlas", "service_updated"),
            ("atlas", "timelock_set"),
            ("atlas", "pending_scheduled"),
            ("atlas", "pending_cancelled"),
        ]
    );
}

#[test]
fn each_named_event_returns_json() {
    let guardian: GuardianSet = payload_as("guardian_set", GUARDIAN_SET_HEX);
    assert!(matches!(guardian.guardian, Account::External(_)));

    let service: ServiceUpdated = payload_as("service_updated", SERVICE_UPDATED_HEX);
    assert_eq!(service.name, "treasury-data");
    assert_eq!(service.id, SERVICE_ID);

    let timelock: TimelockSet = payload_as("timelock_set", TIMELOCK_SET_HEX);
    assert_eq!(timelock.blocks, 86400);

    let scheduled: PendingScheduled = payload_as("pending_scheduled", PENDING_SCHEDULED_HEX);
    assert_eq!(scheduled.change, PendingChange::Timelock(86400));
    assert_eq!(scheduled.execute_at, 100);

    let old = decode(
        CONTRACT,
        "pending_cancelled",
        DEPLOYMENT_VERSION,
        &bytes(PENDING_CANCELLED_V4_HEX),
    )
    .expect("pending_cancelled v4");
    let cancelled: PendingChange =
        serde_json::from_value(old["payload"]["change"].clone()).expect("change");
    assert_eq!(cancelled, PendingChange::Timelock(86400));
    assert!(old["payload"].get("execute_at").is_none());
}

#[test]
fn pending_cancelled_from_0_6_0_carries_execute_at() {
    let value = decode(
        CONTRACT,
        "pending_cancelled",
        PENDING_CANCELLED_EXECUTE_AT_SINCE,
        &bytes(PENDING_CANCELLED_V5_HEX),
    )
    .expect("pending_cancelled v5");
    let cancelled: PendingCancelled =
        serde_json::from_value(value["payload"].clone()).expect("payload");
    assert_eq!(cancelled.change, PendingChange::Timelock(86400));
    assert_eq!(cancelled.execute_at, 100);

    let rejected = decode(
        CONTRACT,
        "pending_cancelled",
        DEPLOYMENT_VERSION,
        &bytes(PENDING_CANCELLED_V5_HEX),
    );
    assert!(matches!(rejected, Err(DecodeError::InvalidPayload { .. })));
}

#[test]
fn unknown_topic_errors() {
    let err = decode(
        CONTRACT,
        "reaped",
        DEPLOYMENT_VERSION,
        &bytes(TIMELOCK_SET_HEX),
    )
    .unwrap_err();
    assert_eq!(
        err,
        DecodeError::UnknownTopic {
            contract: CONTRACT.to_owned(),
            topic: "reaped".to_owned(),
        }
    );
}

#[test]
fn topic_alone_does_not_dispatch() {
    let err = decode(
        "knot",
        "timelock_set",
        DEPLOYMENT_VERSION,
        &bytes(TIMELOCK_SET_HEX),
    )
    .unwrap_err();
    assert!(matches!(err, DecodeError::UnknownContract { .. }));
}

#[test]
fn version_comes_from_the_caller_not_the_bytes() {
    let err = decode(CONTRACT, "timelock_set", 2_000, &bytes(TIMELOCK_SET_HEX)).unwrap_err();
    assert_eq!(err, DecodeError::UnsupportedVersion { version: 2_000 });
}

#[test]
fn garbled_payload_errors() {
    let err = decode(CONTRACT, "timelock_set", DEPLOYMENT_VERSION, &[0xff]).unwrap_err();
    assert!(matches!(err, DecodeError::InvalidPayload { .. }));
}

#[test]
fn every_supported_version_decodes_the_same_layout() {
    assert!(SUPPORTED_VERSIONS.contains(&DEPLOYMENT_VERSION));
    for version in SUPPORTED_VERSIONS {
        let value = decode(CONTRACT, "timelock_set", *version, &bytes(TIMELOCK_SET_HEX))
            .expect("supported version");
        assert_eq!(value["version"], *version);
        assert_eq!(value["payload"]["blocks"], 86400);
    }
}

#[test]
fn superseded_and_unreleased_versions_are_rejected() {
    // 0.3.0 could not be initialised; 0.7.0 is not a record this crate knows.
    for version in [3_000, 7_000] {
        let err = decode(CONTRACT, "timelock_set", version, &bytes(TIMELOCK_SET_HEX)).unwrap_err();
        assert_eq!(err, DecodeError::UnsupportedVersion { version });
    }
}

#[test]
fn guardian_accepted_decodes_from_0_5_0_on() {
    let value = decode(
        CONTRACT,
        "guardian_accepted",
        GUARDIAN_ACCEPTED_SINCE,
        &bytes(GUARDIAN_ACCEPTED_HEX),
    )
    .expect("guardian_accepted");
    let ev: GuardianAccepted = serde_json::from_value(value["payload"].clone()).expect("payload");
    assert_eq!(ev.guardian, Account::Contract(SERVICE_ID));
    assert_eq!(ev.execute_at, 100);
}

#[test]
fn guardian_accepted_is_unknown_before_0_5_0() {
    for version in SUPPORTED_VERSIONS
        .iter()
        .filter(|v| **v < GUARDIAN_ACCEPTED_SINCE)
    {
        let err = decode(
            CONTRACT,
            "guardian_accepted",
            *version,
            &bytes(GUARDIAN_ACCEPTED_HEX),
        )
        .unwrap_err();
        assert!(matches!(err, DecodeError::UnknownTopic { .. }), "{version}");
    }
}
