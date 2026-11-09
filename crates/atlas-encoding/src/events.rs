//! Host-visible event payloads for Atlas mutations.
//!
//! Struct Archive types carry `#[archive_attr(repr(C))]`. Nested data-carrying
//! enums (`Account`, `PendingChange`) skip that attribute on their own
//! definitions — rustc rejects it on archived enums.

use alloc::string::String;

use bytecheck::CheckBytes;
use dusk_core::abi::ContractId;
use rkyv::{Archive, Deserialize, Serialize};

use crate::call_types::{Account, PendingChange};

#[derive(Debug, Clone, PartialEq, Eq, Archive, Serialize, Deserialize)]
#[archive_attr(derive(CheckBytes))]
#[archive_attr(repr(C))]
#[cfg_attr(feature = "data-driver", derive(serde::Serialize, serde::Deserialize))]
pub struct GuardianSet {
    pub guardian: Account,
}

/// The incoming guardian of the pending guardian change called
/// `accept_guardian`. `guardian` is that account (the actor); `execute_at` is
/// the height from which the change can apply. `guardian_set` follows when
/// the change applies, in the same call if the delay has already passed.
/// Added in `atlas-encoding` 0.4.0 / `atlas` 0.5.0.
#[derive(Debug, Clone, PartialEq, Eq, Archive, Serialize, Deserialize)]
#[archive_attr(derive(CheckBytes))]
#[archive_attr(repr(C))]
#[cfg_attr(feature = "data-driver", derive(serde::Serialize, serde::Deserialize))]
pub struct GuardianAccepted {
    pub guardian: Account,
    pub execute_at: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Archive, Serialize, Deserialize)]
#[archive_attr(derive(CheckBytes))]
#[archive_attr(repr(C))]
#[cfg_attr(feature = "data-driver", derive(serde::Serialize, serde::Deserialize))]
pub struct ServiceUpdated {
    pub name: String,
    pub id: ContractId,
}

#[derive(Debug, Clone, PartialEq, Eq, Archive, Serialize, Deserialize)]
#[archive_attr(derive(CheckBytes))]
#[archive_attr(repr(C))]
#[cfg_attr(feature = "data-driver", derive(serde::Serialize, serde::Deserialize))]
pub struct TimelockSet {
    pub blocks: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Archive, Serialize, Deserialize)]
#[archive_attr(derive(CheckBytes))]
#[archive_attr(repr(C))]
#[cfg_attr(feature = "data-driver", derive(serde::Serialize, serde::Deserialize))]
pub struct PendingScheduled {
    pub change: PendingChange,
    pub execute_at: u64,
}

/// A pending guardian change or delay change was withdrawn before it applied.
/// `execute_at` is the height that change would have applied at.
/// Present from `atlas-encoding` 0.5.0 / `atlas` 0.6.0. The 0.4.0 payload is
/// `change` only.
#[derive(Debug, Clone, PartialEq, Eq, Archive, Serialize, Deserialize)]
#[archive_attr(derive(CheckBytes))]
#[archive_attr(repr(C))]
#[cfg_attr(feature = "data-driver", derive(serde::Serialize, serde::Deserialize))]
pub struct PendingCancelled {
    pub change: PendingChange,
    pub execute_at: u64,
}

/// `ContractEvent` topic impls, needed only by the contract macro
/// (`#[dusk_forge::contract(events = [...])]`). Host consumers decoding
/// events leave the `contract-events` feature off.
#[cfg(feature = "contract-events")]
mod topics {
    use super::*;
    use dusk_forge::ContractEvent;

    impl ContractEvent for GuardianSet {
        const TOPICS: &'static [&'static str] = &["guardian_set"];
    }

    impl ContractEvent for GuardianAccepted {
        const TOPICS: &'static [&'static str] = &["guardian_accepted"];
    }

    impl ContractEvent for ServiceUpdated {
        const TOPICS: &'static [&'static str] = &["service_updated"];
    }

    impl ContractEvent for TimelockSet {
        const TOPICS: &'static [&'static str] = &["timelock_set"];
    }

    impl ContractEvent for PendingScheduled {
        const TOPICS: &'static [&'static str] = &["pending_scheduled"];
    }

    impl ContractEvent for PendingCancelled {
        const TOPICS: &'static [&'static str] = &["pending_cancelled"];
    }
}
