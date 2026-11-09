## Summary

<!-- What changed and why? Link issues if applicable. -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Contract / ABI / event-payload change (requires coordinated redeploy)
- [ ] Documentation
- [ ] CI / tooling
- [ ] EVM (`evm/src`, `evm/script`)

## Checklist

- [ ] `cargo fmt --all --check`, `make clippy`, and `make test` pass locally
- [ ] If `evm/` changed: `make evm-fmt`, `make evm-test`, and
      `make evm-script-test` pass
- [ ] Layout goldens untouched, or regenerated with the reason stated and a
      `PINNED-DIFFERENT-REDEPLOYED` changelog entry
- [ ] No secrets, `.env`, or absolute local paths in the diff
- [ ] `CHANGELOG.md` updated if user-visible behaviour changed
- [ ] Authority-rule or timelock changes called out explicitly in the description

## Test plan

<!-- Commands run and results. For contract changes, note deploy/pin impact on consumers. -->
