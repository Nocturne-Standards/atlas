# Using Atlas from a consumer contract

Atlas is never upgraded. A consumer bakes the `ContractId` of one Atlas
deployment into its own build and calls `resolve(name)` at runtime. This page
is what to do, and what to check, before trusting an id.

## Bake the id

Set `ATLAS_PIN_HEX` to the 64 hex digits of the Atlas `ContractId` and let a
`build.rs` write the constant. The template below fails the build when the id
is missing, the wrong length, not hex, or all zero, accepts a `0x` prefix and
either case, and rebuilds when the variable changes (without
`rerun-if-env-changed` Cargo keeps a stale id baked in).

```rust
//! Bakes the Atlas ContractId into the build. Fails the build, loudly, when the
//! id is missing or malformed. Rebuilds when ATLAS_PIN_HEX changes.
use std::{env, fs, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=ATLAS_PIN_HEX");
    let raw = env::var("ATLAS_PIN_HEX")
        .expect("set ATLAS_PIN_HEX to the 64-hex-digit Atlas ContractId from the deployments record");
    let hex = raw.trim();
    let hex = hex.strip_prefix("0x").or_else(|| hex.strip_prefix("0X")).unwrap_or(hex);
    assert!(
        hex.len() == 64 && hex.bytes().all(|b| b.is_ascii_hexdigit()),
        "ATLAS_PIN_HEX must be exactly 64 hex digits (32 bytes), got {} characters",
        hex.len()
    );
    let mut bytes = [0u8; 32];
    for (i, byte) in bytes.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).expect("hex digit");
    }
    assert!(bytes != [0u8; 32], "ATLAS_PIN_HEX is the all-zero id");

    let out = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR")).join("atlas_id.rs");
    fs::write(out, format!("pub const ATLAS_ID_BYTES: [u8; 32] = {bytes:?};\n")).expect("write atlas_id.rs");
}
```

Use it with:

```rust
mod pin {
    include!(concat!(env!("OUT_DIR"), "/atlas_id.rs"));
}
// pin::ATLAS_ID_BYTES is the [u8; 32] to build a ContractId from.
```

Read service ids with `resolve(name)` at runtime. Do not hardcode the
downstream logic ids.

## Verify an id before you pin it

An id is a trust anchor: whoever is Atlas's guardian can repoint every name.
A lookalike contract can be deployed with someone else as guardian. Check all
of these, on the network you will run on:

1. **The id is in the public deployments record**
   ([Nocturne-Standards/nocturne-deployments](https://github.com/Nocturne-Standards/nocturne-deployments),
   `contracts.atlas`), under the network you target. A testnet id means nothing
   on another network.
2. **Read the state on the pinned id**: `guardian()`, `timelock_blocks()` and
   `pending()`. The guardian should be the warden contract the record names,
   the timelock the value the record names, and `pending()` empty.
3. **Check the warden both ways.** The warden's `atlas()` must return the
   pinned id, and Atlas's `guardian()` must return the warden. One direction
   alone does not tell you the two are paired: a warden can be deployed
   against any Atlas, and a fake Atlas can name any warden.
4. **Check the code.** The record carries `wasm_sha256`, the hash of the WASM
   that was submitted. Hash the deployed contract's bytecode from your node and
   compare. What a node returns for a contract depends on its API, so confirm
   the comparison method once against a deployment you know before relying on
   it.
5. **Know whether the hash is reproducible.** From 0.4.1 the WASM is built by
   `make release-wasm` on Linux; the CI `atlas-wasm` artifact and
   `scripts/release-wasm-docker.sh` give the same bytes (a macOS build does
   not: see `docs/versioning.md`). Older versions are history; no hash is
   recorded for 0.3.1, so its bytecode cannot be checked against source.

The delay is a reaction window, not a veto: a compromised guardian or warden
scheduler can repoint a name after the delay and nothing inside Atlas stops it.
Watch `service_scheduled` (warden) and `pending_scheduled` (Atlas) for the
instance you pin, and be ready to repin.

## Depend on `atlas-encoding`

Use the crates.io release:

```toml
atlas-encoding = { package = "nocturne-atlas-encoding", version = "0.5" }
```

`atlas-encoding` pins exact versions of `dusk-core`, `rkyv` and `bytecheck`,
because the archived layouts depend on them. Check the pins of the version you
choose: 0.5.x needs `dusk-core =1.7.0`. Knot's encoding crate,
`nocturne-knot-encoding`, also takes `dusk-core` from the registry, so no
`[patch]` is needed when you use both.

## Keys

An `External` guardian or scheduler is a key. Use a dedicated key that signs
nothing else, or a contract account, which is preferred. The genesis transfer
contract can call other contracts for a Moonlight sender
(`contract_to_contract`), and the signer stays `public_sender`. Atlas 0.5.0
accepts a key only when the transfer contract is the one frame below it, so
that relay is refused. Atlas 0.4.1 (on testnet) and knot-warden 0.2.1 check
only that `caller` is the transfer contract, so a malicious contract the key is
tricked into calling can reach their argument-free calls (`cancel_pending`,
`accept_guardian`, and the warden's `cancel_admin`,
`cancel_atlas_pending`, `accept_*`). A forged `set_timelock` or `set_delay`
value is always above the cap and is refused.
