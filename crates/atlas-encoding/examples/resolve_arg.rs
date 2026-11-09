//! Encode a Dusk `resolve(String)` argument, and decode `Option<ContractId>`.
//!
//! The drift script uses this so the rkyv bytes match `atlas-encoding`'s
//! pinned rkyv. Stdout is hex only.
//!
//!   cargo run -p nocturne-atlas-encoding --example resolve_arg -- encode native.attested-nav
//!   cargo run -p nocturne-atlas-encoding --example resolve_arg -- decode < response.hex

use std::env;
use std::io::{self, Read};
use std::process::ExitCode;

use dusk_core::abi::ContractId;
use rkyv::Deserialize;

fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    let cmd = match args.next() {
        Some(cmd) => cmd,
        None => {
            eprintln!("usage: resolve_arg encode <name> | decode");
            return ExitCode::from(2);
        }
    };
    match cmd.as_str() {
        "encode" => {
            let name = match args.next() {
                Some(name) => name,
                None => {
                    eprintln!("encode needs a name");
                    return ExitCode::from(2);
                }
            };
            let bytes = rkyv::to_bytes::<_, 256>(&name).unwrap_or_else(|err| {
                eprintln!("rkyv encode failed: {err}");
                std::process::exit(1);
            });
            println!("{}", hex(&bytes));
            ExitCode::SUCCESS
        }
        "decode" => {
            let mut hex_in = String::new();
            io::stdin().read_to_string(&mut hex_in).expect("stdin");
            let bytes = match unhex(hex_in.trim()) {
                Ok(bytes) => bytes,
                Err(err) => {
                    eprintln!("decode hex: {err}");
                    return ExitCode::from(1);
                }
            };
            match decode_option_id(&bytes) {
                Ok(Some(id)) => {
                    println!("{}", hex(&id.to_bytes()));
                    ExitCode::SUCCESS
                }
                Ok(None) => {
                    println!("none");
                    ExitCode::SUCCESS
                }
                Err(err) => {
                    eprintln!("rkyv decode failed: {err}");
                    ExitCode::from(1)
                }
            }
        }
        other => {
            eprintln!("unknown command {other}");
            ExitCode::from(2)
        }
    }
}

fn decode_option_id(bytes: &[u8]) -> Result<Option<ContractId>, String> {
    let mut aligned = rkyv::AlignedVec::new();
    aligned.extend_from_slice(bytes);
    let archived =
        rkyv::check_archived_root::<Option<ContractId>>(&aligned).map_err(|err| err.to_string())?;
    let value: Option<ContractId> = archived
        .deserialize(&mut rkyv::Infallible)
        .map_err(|_| "deserialize".to_string())?;
    Ok(value)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(input: &str) -> Result<Vec<u8>, String> {
    let s = input.strip_prefix("0x").unwrap_or(input);
    if !s.is_ascii() {
        return Err("non-ascii".into());
    }
    if !s.len().is_multiple_of(2) {
        return Err("odd length".into());
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|err| err.to_string()))
        .collect()
}
