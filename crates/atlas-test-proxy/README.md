# atlas-test-proxy

Test fixture for the Atlas VM tests (`crates/atlas/tests`). It cross-calls
Atlas so that `abi::caller()` is this contract, and `relay` forwards raw call
bytes so the tests can rebuild the transfer contract's `contract_to_contract`
call stack.

**Never deploy it.** Every method forwards for anyone. Named as a guardian, it
would make Atlas writable by every account, and it can call `accept_guardian`.
It is `publish = false`, built only for the CI test job, and is not part of the
`atlas-wasm` release artifact.
