# atlas

WASM registry contract. Operators: repository root README.

Host-visible types live in `atlas-encoding`. Contract crate is
`publish = false`; pin encoding by git rev or tag, bake `ATLAS_PIN_HEX` at
build time.
