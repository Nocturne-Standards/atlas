# atlas

WASM registry contract. Operators: repository root README.

Host-visible types live in `atlas-encoding`, on crates.io as
`nocturne-atlas-encoding`. Contract crate is `publish = false`; consumers depend
on the encoding crate from the registry and bake `ATLAS_PIN_HEX` at build time.
