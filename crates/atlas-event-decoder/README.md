# atlas-event-decoder

Host library that decodes Atlas contract events to JSON, for indexers and
explorers. It turns the rkyv payload of a named event from
[`nocturne-atlas-encoding`](https://crates.io/crates/nocturne-atlas-encoding)
into a `serde_json::Value`.

```toml
atlas-event-decoder = { package = "nocturne-atlas-event-decoder", version = "0.4" }
```

```rust
use atlas_event_decoder::{decode, DEPLOYMENT_VERSION};

// `bytes` is the event payload; `DEPLOYMENT_VERSION` or the version from
// the deployment record you are indexing.
let json = decode("atlas", "guardian_set", DEPLOYMENT_VERSION, &bytes)?;
```

## What it decodes

Atlas records 0.3.1, 0.4.0, 0.4.1 and 0.6.0 (`SUPPORTED_VERSIONS`). Older
records are not decoded. Topics:

| Topic | Records |
|---|---|
| `guardian_set`, `service_updated`, `timelock_set`, `pending_scheduled` | all supported |
| `pending_cancelled` | all supported; from 0.6.0 the payload also carries `execute_at` |
| `guardian_accepted` | from 0.6.0 on; an older record never emitted it, so the topic is unknown there |

Errors are `DecodeError`: unknown contract, unsupported version, unknown topic,
or a payload that does not match the topic.

## Things to know

- `contract` is a deployments key (`"atlas"`), not a `ContractId`, and the
  version is the deployment record's semver packed as
  `major * 1_000_000 + minor * 1_000 + patch`. Neither is read from the bytes.
- The bytes carry no emitter. Check that the event came from the Atlas
  contract you pinned (the event's source) before you trust the decoded value.
- The payload must be exactly one archived value. Do not hash or compare the
  raw bytes as canonical.
- A release that changes a layout needs its own decoder arm, and its version
  stays out of `SUPPORTED_VERSIONS` until it has one.

Source and docs: <https://github.com/Nocturne-Standards/atlas>. Apache-2.0.
