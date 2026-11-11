//! Front door: resolves `"counter"` via a baked-in Atlas id on every call.

#![cfg_attr(target_family = "wasm", no_std)]
#![cfg(target_family = "wasm")]

#[cfg(not(feature = "contract"))]
compile_error!("Enable the 'contract' feature for WASM builds");

extern crate alloc;

#[dusk_forge::contract]
mod atlas_example_front_contract {
    use alloc::string::String;

    use dusk_core::abi::{self, ContractId};

    mod pin {
        include!(concat!(env!("OUT_DIR"), "/atlas_pin.rs"));
    }

    const ATLAS_ID: ContractId = ContractId::from_bytes(pin::ATLAS_ID_BYTES);
    const SERVICE: &str = "counter";

    pub struct FrontState;

    impl FrontState {
        pub const fn new() -> Self {
            Self
        }

        pub fn increment(&mut self) {
            let name = String::from(SERVICE);
            let found: Option<ContractId> =
                abi::call(ATLAS_ID, "resolve", &name).expect("atlas resolve failed");
            let counter = found.expect("atlas has no counter");
            let _: () = abi::call(counter, "increment", &()).expect("counter increment failed");
        }

        pub fn value(&self) -> u64 {
            let name = String::from(SERVICE);
            let found: Option<ContractId> =
                abi::call(ATLAS_ID, "resolve", &name).expect("atlas resolve failed");
            let counter = found.expect("atlas has no counter");
            abi::call(counter, "value", &()).expect("counter value failed")
        }
    }
}
