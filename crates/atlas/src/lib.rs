//! Atlas: per-project service registry and guardian.
//!
//! Never-upgraded fixed point for a deployment. Consumers bake this contract's
//! id and call `resolve`. The guardian is one [`atlas_encoding::call_types::Account`]:
//! a BLS key on a direct call, or a contract id matched against `abi::caller()`.
//! Replacing the guardian, and changing that delay, are the only writes that wait.
//! See the repository README.

#![cfg_attr(target_family = "wasm", no_std)]
#![cfg(target_family = "wasm")]

#[cfg(not(any(feature = "contract", feature = "data-driver")))]
compile_error!("Enable either 'contract' or 'data-driver' feature for WASM builds");

extern crate alloc;

#[cfg(target_family = "wasm")]
mod state;
