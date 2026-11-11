//! Minimal counter for the Atlas consumer example (docs + host test).

#![cfg_attr(target_family = "wasm", no_std)]
#![cfg(target_family = "wasm")]

#[cfg(not(feature = "contract"))]
compile_error!("Enable the 'contract' feature for WASM builds");

#[dusk_forge::contract]
mod atlas_example_counter_contract {
    /// A single saturating counter — no Atlas dependency.
    pub struct CounterState {
        n: u64,
    }

    impl CounterState {
        pub const fn new() -> Self {
            Self { n: 0 }
        }

        pub fn increment(&mut self) {
            self.n = self.n.saturating_add(1);
        }

        pub fn value(&self) -> u64 {
            self.n
        }
    }
}
