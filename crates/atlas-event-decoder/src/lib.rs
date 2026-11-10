//! Host decoder for the named Atlas events in `atlas-encoding`.
//!
//! Dispatch is the deployments key plus the topic. `version` is the
//! deployment-record semver, packed `major * 1_000_000 + minor * 1_000 + patch`.
//! It is not read from `bytes`. Every supported record emits the five
//! `atlas-encoding` 0.3.0 event payloads with the same layout, except
//! `pending_cancelled`: from [`PENDING_CANCELLED_EXECUTE_AT_SINCE`] (`atlas`
//! 0.6.0, `atlas-encoding` 0.5.0) that payload also carries `execute_at`.
//! `guardian_accepted` (`atlas-encoding` 0.4.0) is the sixth payload. It
//! decodes only for records from [`GUARDIAN_ACCEPTED_SINCE`] on; an older
//! record never emitted it, so the topic is unknown there. A release that
//! changes a layout needs its own decoder arm, and its version stays out of
//! [`SUPPORTED_VERSIONS`] until it has one. Older records are not decoded.
//!
//! `contract` is a deployments key, not a `ContractId`, and the bytes carry no
//! emitter. The caller must already know the event came from the pinned Atlas
//! (the event's `source`); a lookalike contract's events decode just as well.
//! The payload must be exactly one archived value: leading bytes are tolerated
//! by the archive check, so do not hash or compare the raw bytes as canonical.

use atlas_encoding::events::{
    GuardianAccepted, GuardianSet, PendingCancelled, PendingScheduled, ServiceUpdated, TimelockSet,
};
use rkyv::Deserialize;
use rkyv::validation::validators::DefaultValidator;
use serde::Serialize;
use serde_json::{Value, json};

/// Deployments manifest key for the Atlas contract.
pub const CONTRACT: &str = "atlas";

/// `contracts.atlas.current.version` `0.4.1`
/// (`fd2b8594031d56ae584301976e26f7348aaaea3a9900d2967201789f1b4e4ce9`).
pub const DEPLOYMENT_VERSION: u32 = 4_001;

/// Records this crate decodes: 0.3.1, 0.4.0, 0.4.1 and 0.6.0.
/// 0.6.0 adds `guardian_accepted` and `execute_at` on `pending_cancelled`.
/// 0.3.0 is absent: that deploy could not be initialised and was superseded.
pub const SUPPORTED_VERSIONS: &[u32] = &[3_001, 4_000, 4_001, 6_000];

/// First record version that emits `guardian_accepted` (`atlas` 0.6.0).
pub const GUARDIAN_ACCEPTED_SINCE: u32 = 6_000;

/// First record whose `pending_cancelled` carries `execute_at` (`atlas` 0.6.0).
pub const PENDING_CANCELLED_EXECUTE_AT_SINCE: u32 = 6_000;

/// `(contract, topic)` arms this crate decodes.
pub const ARMS: &[(&str, &str)] = &[
    (CONTRACT, "guardian_set"),
    (CONTRACT, "guardian_accepted"),
    (CONTRACT, "service_updated"),
    (CONTRACT, "timelock_set"),
    (CONTRACT, "pending_scheduled"),
    (CONTRACT, "pending_cancelled"),
];

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum DecodeError {
    #[error("unknown contract {contract}")]
    UnknownContract { contract: String },
    #[error("unsupported deployment version {version}")]
    UnsupportedVersion { version: u32 },
    #[error("unknown topic {topic} for contract {contract}")]
    UnknownTopic { contract: String, topic: String },
    #[error("payload does not match {topic}: {reason}")]
    InvalidPayload { topic: String, reason: String },
}

/// Decode one Atlas event.
///
/// `contract` is the deployments key (`atlas`). `version` is
/// one of [`SUPPORTED_VERSIONS`] ([`DEPLOYMENT_VERSION`] for the current record). `bytes` are the rkyv
/// payload of the named `atlas-encoding` event for `topic`.
pub fn decode(
    contract: &str,
    topic: &str,
    version: u32,
    bytes: &[u8],
) -> Result<Value, DecodeError> {
    if contract != CONTRACT {
        return Err(DecodeError::UnknownContract {
            contract: contract.to_owned(),
        });
    }
    if !SUPPORTED_VERSIONS.contains(&version) {
        return Err(DecodeError::UnsupportedVersion { version });
    }
    let payload = match topic {
        "guardian_set" => event_json::<GuardianSet>(topic, bytes)?,
        "guardian_accepted" if version >= GUARDIAN_ACCEPTED_SINCE => {
            event_json::<GuardianAccepted>(topic, bytes)?
        }
        "service_updated" => event_json::<ServiceUpdated>(topic, bytes)?,
        "timelock_set" => event_json::<TimelockSet>(topic, bytes)?,
        "pending_scheduled" => event_json::<PendingScheduled>(topic, bytes)?,
        "pending_cancelled" if version >= PENDING_CANCELLED_EXECUTE_AT_SINCE => {
            event_json::<PendingCancelled>(topic, bytes)?
        }
        "pending_cancelled" => pending_cancelled_v4::json(topic, bytes)?,
        _ => {
            return Err(DecodeError::UnknownTopic {
                contract: contract.to_owned(),
                topic: topic.to_owned(),
            });
        }
    };
    Ok(json!({
        "contract": contract,
        "topic": topic,
        "version": version,
        "payload": payload,
    }))
}

fn event_json<T>(topic: &str, bytes: &[u8]) -> Result<Value, DecodeError>
where
    T: rkyv::Archive + Serialize,
    T::Archived:
        for<'a> bytecheck::CheckBytes<DefaultValidator<'a>> + Deserialize<T, rkyv::Infallible>,
{
    let archived =
        rkyv::check_archived_root::<T>(bytes).map_err(|err| DecodeError::InvalidPayload {
            topic: topic.to_owned(),
            reason: err.to_string(),
        })?;
    let value =
        archived
            .deserialize(&mut rkyv::Infallible)
            .map_err(|err| DecodeError::InvalidPayload {
                topic: topic.to_owned(),
                reason: err.to_string(),
            })?;
    serde_json::to_value(value).map_err(|err| DecodeError::InvalidPayload {
        topic: topic.to_owned(),
        reason: err.to_string(),
    })
}

/// `pending_cancelled` before atlas 0.6.0: the change, and no `execute_at`.
/// The archived layout matches `atlas-encoding` 0.4.0.
mod pending_cancelled_v4 {
    use atlas_encoding::call_types::PendingChange;
    use bytecheck::CheckBytes;
    use rkyv::{Archive, Deserialize, Serialize};
    use serde_json::{Value, json};

    use crate::DecodeError;

    #[derive(Archive, Deserialize, Serialize)]
    #[archive_attr(derive(CheckBytes))]
    #[archive_attr(repr(C))]
    struct PendingCancelledV4 {
        change: PendingChange,
    }

    pub fn json(topic: &str, bytes: &[u8]) -> Result<Value, DecodeError> {
        let archived = rkyv::check_archived_root::<PendingCancelledV4>(bytes).map_err(|err| {
            DecodeError::InvalidPayload {
                topic: topic.to_owned(),
                reason: err.to_string(),
            }
        })?;
        let value: PendingCancelledV4 =
            archived.deserialize(&mut rkyv::Infallible).map_err(|err| {
                DecodeError::InvalidPayload {
                    topic: topic.to_owned(),
                    reason: err.to_string(),
                }
            })?;
        let change =
            serde_json::to_value(&value.change).map_err(|err| DecodeError::InvalidPayload {
                topic: topic.to_owned(),
                reason: err.to_string(),
            })?;
        Ok(json!({ "change": change }))
    }
}
