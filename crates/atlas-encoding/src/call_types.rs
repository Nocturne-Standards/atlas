//! Host-visible argument / view types for Atlas.
//!
//! Struct Archive types carry `#[archive_attr(repr(C))]`; data-carrying enums
//! cannot, so their pin is the layout golden.

use alloc::string::String;

use bytecheck::CheckBytes;
use dusk_core::abi::ContractId;
use dusk_core::signatures::bls::PublicKey as BlsPublicKey;
use rkyv::{Archive, Deserialize, Serialize};

/// Guardian identity. A key is a direct Moonlight call. A contract is
/// `abi::caller()`. Atlas never calls the guardian.
///
/// Data-carrying enum: `#[archive_attr(repr(C))]` is rejected by rustc
/// ("enums may only be repr(i*) or repr(u*)"). Pin is the layout golden
/// in `tests/layout_goldens.rs` — not `archive_attr`.
#[derive(Debug, Clone, PartialEq, Eq, Archive, Serialize, Deserialize)]
#[archive_attr(derive(CheckBytes))]
#[cfg_attr(feature = "data-driver", derive(serde::Serialize, serde::Deserialize))]
pub enum Account {
    /// Direct call: `caller` is unset, or it is the genesis transfer contract,
    /// and `public_sender` equals this key.
    External(BlsPublicKey),
    /// Inter-contract call: `caller` equals this id.
    Contract(ContractId),
}

#[derive(Debug, Clone, PartialEq, Eq, Archive, Serialize, Deserialize)]
#[archive_attr(derive(CheckBytes))]
#[archive_attr(repr(C))]
#[cfg_attr(feature = "data-driver", derive(serde::Serialize, serde::Deserialize))]
pub struct InitArgs {
    pub guardian: Account,
    pub timelock_blocks: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Archive, Serialize, Deserialize)]
#[archive_attr(derive(CheckBytes))]
#[archive_attr(repr(C))]
#[cfg_attr(feature = "data-driver", derive(serde::Serialize, serde::Deserialize))]
pub struct SetServiceArgs {
    pub name: String,
    pub id: ContractId,
}

/// Scheduled guardian replacement or delay change.
///
/// Data-carrying enum: `#[archive_attr(repr(C))]` is rejected by rustc
/// ("enums may only be repr(i*) or repr(u*)"). Pin is the layout golden
/// in `tests/layout_goldens.rs` — not `archive_attr`.
#[derive(Debug, Clone, PartialEq, Eq, Archive, Serialize, Deserialize)]
#[archive_attr(derive(CheckBytes))]
#[cfg_attr(feature = "data-driver", derive(serde::Serialize, serde::Deserialize))]
pub enum PendingChange {
    Guardian(Account),
    Timelock(u64),
}

#[derive(Debug, Clone, PartialEq, Eq, Archive, Serialize, Deserialize)]
#[archive_attr(derive(CheckBytes))]
#[archive_attr(repr(C))]
#[cfg_attr(feature = "data-driver", derive(serde::Serialize, serde::Deserialize))]
pub struct PendingView {
    pub change: PendingChange,
    pub execute_at: u64,
}
