//! Test-only proxy: cross-calls Atlas so `abi::caller()` is this contract.
//!
//! Never deploy it. It forwards any call for anyone: named as a guardian, it
//! would make Atlas writable by every account.

#![cfg_attr(target_family = "wasm", no_std)]
#![cfg(target_family = "wasm")]

#[cfg(not(feature = "contract"))]
compile_error!("Enable the 'contract' feature for WASM builds");

extern crate alloc;

#[dusk_forge::contract]
mod atlas_test_proxy_contract {
    use alloc::string::String;
    use alloc::vec::Vec;

    use dusk_core::abi::{self, ContractId};

    use atlas_encoding::call_types::{InitArgs, SetServiceArgs};

    pub struct ProxyState;

    impl ProxyState {
        pub const fn new() -> Self {
            Self
        }

        /// Cross-call Atlas `init_guardian` — `abi::caller()` at Atlas is this contract.
        pub fn call_init_guardian(&self, atlas: ContractId, args: InitArgs) {
            let _: () = abi::call(atlas, "init_guardian", &args)
                .expect("proxy → atlas init_guardian failed");
        }

        /// Cross-call Atlas `accept_guardian` — `abi::caller()` at Atlas is this contract.
        pub fn call_accept_guardian(&self, atlas: ContractId) {
            let _: () = abi::call(atlas, "accept_guardian", &())
                .expect("proxy → atlas accept_guardian failed");
        }

        /// Forward raw call bytes to `target.fn_name` and return the raw
        /// reply. Deployed at the transfer contract id as well as at its own
        /// id, two relays rebuild the `contract_to_contract` call stack
        /// (transfer → contract → transfer → Atlas) that the direct-call
        /// check must refuse.
        pub fn relay(&self, target: ContractId, fn_name: String, data: Vec<u8>) -> Vec<u8> {
            abi::call_raw(target, &fn_name, &data).expect("proxy relay failed")
        }

        /// Cross-call Atlas `set_service` — `abi::caller()` at Atlas is this contract.
        pub fn call_set_service(&self, atlas: ContractId, name: String, id: ContractId) {
            let args = SetServiceArgs { name, id };
            let _: () =
                abi::call(atlas, "set_service", &args).expect("proxy → atlas set_service failed");
        }
    }
}
