# Security

## Reporting a vulnerability

Email **security@nocturne-standards.org** with:

- Affected crate or contract (`atlas`, `atlas-encoding`, `atlas-event-decoder`, `atlas-test-proxy`, `evm/src/*.sol`, `evm/script/*`) or document
- Steps to reproduce (host-side test, VM session transcript, or transaction)
- Impact assessment (which authority check or timelock rule is bypassed)

We aim to acknowledge within **72 hours** and share a remediation timeline for
confirmed issues.

Please do **not** open public GitHub issues for undisclosed vulnerabilities.

## Scope

In scope: this repository's Rust crates, the `atlas` WASM contract, and the
DuskEVM contracts and scripts (`evm/src/*.sol`, `evm/script/*`). That covers
authority checks (`init_guardian`, external and contract guardians, and
`msg.sender == guardian` on EvmAtlas), the timelock lifecycle (`set_guardian`,
`set_timelock`, `cancel_pending`, `execute_pending`, and the warden delay in
front of a repoint), event emission, and the rkyv layout of `atlas-encoding`
types.

Out of scope: knot (quorum verification, proposals execution), Dusk
node software and testnet infrastructure, hosted deployments we do not
operate, and social-engineering attacks. Report knot issues to the knot
repository's security contact.

## Safe use

- **Testnet only** — no mainnet deployment claim; do not use production keys.
- **Atlas holds no funds.** It resolves names. A compromised guardian can
  repoint a service immediately (behind a warden, after its delay), and can
  replace itself after `timelock_blocks` (plus the warden delay). It cannot
  move assets by itself.
- **Leave `timelock_blocks` at zero only in the lab.** Pass the production
  delay to `init_guardian`. After that, `set_timelock` waits out the current delay, and
  `pending_scheduled` is the window on a guardian change.
- **Pin `atlas-encoding` by full commit** (`rev`), not tag: tags are unsigned
  and movable. Verify the deployed Atlas id before baking it into a consumer
  (see [`docs/consumers.md`](docs/consumers.md)): read its `guardian` and
  `timelock_blocks`, and check the pairing with the warden in both directions.
- **Dedicated keys.** An `External` guardian or scheduler key must sign
  nothing else; a contract it is tricked into calling can reach no-argument
  calls such as `cancel_pending`. Prefer a contract account.
- **Know the deployed version.** Testnet runs Atlas 0.4.1 with knot-warden
  0.2.1 as guardian. Older Atlas versions (history, in `CHANGELOG.md`) lack
  the zero-id, reserved-id and key-validity checks added in 0.4.1, and 0.3.1
  lacks the name and timelock caps too. EvmAtlas and EvmWarden 0.4.1 are on
  DuskEVM testnet (chain 745).
- **Read the first guardian back after deploying.** `init_guardian` sets it
  with no acceptance step. Later guardian changes need the incoming guardian to
  call `accept_guardian` (0.4.1 and later), so a mistyped address can no longer
  take the slot; older versions lack that.

See [`docs/security-model.md`](docs/security-model.md) for the full trust model.
