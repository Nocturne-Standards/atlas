# Atlas workspace Makefile — wasm, knot-wasm, test, clippy, fmt.
# Not a generic contract template.

WASM_TARGET := wasm32-unknown-unknown

# -----------------------------------------------------------------------------
# Knot (public git) — WASM for atlas e2e against registry/proposals
# -----------------------------------------------------------------------------

KNOT_REPO ?= https://github.com/Nocturne-Standards/knot.git
# Rev comes from the knot-encoding pin in Cargo.lock; override with KNOT_REV=.
# The `#` before the SHA is backslash-escaped: unescaped, make would read the
# rest of the line as a comment and never close the $(shell ...) call.
KNOT_REV_SED := sed -n 's|^source = "git+https://github.com/Nocturne-Standards/knot?[^\#]*\#\([0-9a-f]\{40\}\)".*|\1|p'
KNOT_REV ?= $(shell $(KNOT_REV_SED) $(CURDIR)/Cargo.lock | head -n1)
KNOT_SRC := $(CURDIR)/target/knot-src
KNOT_REGISTRY_WASM := $(KNOT_SRC)/target/contract/$(WASM_TARGET)/release/knot_registry.wasm
KNOT_PROPOSALS_WASM := $(KNOT_SRC)/target/contract/$(WASM_TARGET)/release/knot_proposals.wasm
# The data contracts bake in the Atlas id they call. The e2e suite deploys Atlas
# under 0xa7 x 32 (ATLAS_ID in crates/atlas/tests/e2e_multisig.rs).
KNOT_E2E_ATLAS_PIN := a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7
KNOT_REGISTRY_DATA_WASM := $(KNOT_SRC)/target/contract/$(WASM_TARGET)/release/knot_registry_data.wasm
KNOT_PROPOSALS_DATA_WASM := $(KNOT_SRC)/target/contract/$(WASM_TARGET)/release/knot_proposals_data.wasm

.PHONY: knot-wasm
knot-wasm: ## Clone knot @ KNOT_REV (from Cargo.lock unless overridden) and build registry, proposals and their data contracts as WASM
	@if [ -z "$(KNOT_REV)" ]; then \
		echo "Error: KNOT_REV empty — pin knot-encoding in Cargo.lock or pass KNOT_REV="; \
		exit 1; \
	fi
	@if [ ! -d "$(KNOT_SRC)/.git" ]; then \
		echo "Cloning knot → $(KNOT_SRC)"; \
		git clone "$(KNOT_REPO)" "$(KNOT_SRC)"; \
	fi
	@echo "Checking out knot $(KNOT_REV)"
	@git -C "$(KNOT_SRC)" fetch origin
	@git -C "$(KNOT_SRC)" checkout -f "$(KNOT_REV)"
	@$(MAKE) -C "$(KNOT_SRC)/crates/knot-registry" wasm
	@$(MAKE) -C "$(KNOT_SRC)/crates/knot-proposals" wasm
	@$(MAKE) -C "$(KNOT_SRC)/crates/knot-registry-data" wasm ATLAS_PIN_HEX=$(KNOT_E2E_ATLAS_PIN)
	@$(MAKE) -C "$(KNOT_SRC)/crates/knot-proposals-data" wasm ATLAS_PIN_HEX=$(KNOT_E2E_ATLAS_PIN)

.PHONY: wasm
wasm: ## Build atlas + atlas-test-proxy contract WASM
	@$(MAKE) -C crates/atlas wasm
	@$(MAKE) -C crates/atlas-test-proxy wasm

# Deployed bytecode: clean build, wasm-opt required at the pinned version. The
# hash printed here is what `wasm_sha256` in the deployments record must match.
.PHONY: release-wasm
release-wasm: ## Build atlas.wasm for deploy (wasm-opt required, clean build) and print its sha256
	@test "$$(rustc --version | cut -d' ' -f2)" = "1.94.0" || { \
		echo "release-wasm: rustc must be 1.94.0 (found: $$(rustc --version)). Use rustup so rust-toolchain.toml applies."; exit 1; }
	@if [ -f "$${CARGO_HOME:-$$HOME/.cargo}/config.toml" ] || [ -f "$${CARGO_HOME:-$$HOME/.cargo}/config" ]; then \
		echo "release-wasm: note: a Cargo config exists in CARGO_HOME; [profile], [patch] or [source] there would change the bytes."; fi
	@rm -rf target/contract
	@env -u RUSTFLAGS -u CARGO_ENCODED_RUSTFLAGS -u CARGO_BUILD_RUSTFLAGS \
		$$(env | sed -n 's/^\(CARGO_PROFILE_[^=]*\)=.*/-u \1/p') \
		$(MAKE) -C crates/atlas wasm REQUIRE_WASM_OPT=1
	@f=target/contract/$(WASM_TARGET)/release/atlas.wasm; \
		echo "wasm-opt: $$(wasm-opt --version)"; \
		echo "size:     $$(wc -c < $$f | tr -d ' ') bytes"; \
		echo "sha256:   $$(shasum -a 256 $$f | cut -d' ' -f1)"

.PHONY: test
test: wasm knot-wasm ## Build WASM then cargo test --workspace --release
	@test -f "$(KNOT_REGISTRY_WASM)" && test -f "$(KNOT_PROPOSALS_WASM)" && test -f "$(KNOT_REGISTRY_DATA_WASM)" && test -f "$(KNOT_PROPOSALS_DATA_WASM)"
	@cargo test --workspace --release

.PHONY: clippy
clippy: wasm knot-wasm ## Workspace clippy then wasm-target clippy for contracts
	@test -f "$(KNOT_REGISTRY_WASM)" && test -f "$(KNOT_PROPOSALS_WASM)" && test -f "$(KNOT_REGISTRY_DATA_WASM)" && test -f "$(KNOT_PROPOSALS_DATA_WASM)"
	@cargo clippy --workspace --all-targets --release -- -D warnings
	@$(MAKE) -C crates/atlas clippy
	@$(MAKE) -C crates/atlas-test-proxy clippy

.PHONY: fmt
fmt: ## rustfmt check
	@cargo fmt --all --check

.PHONY: evm-fmt
evm-fmt: ## forge fmt check for evm/. Not part of `make test`.
	@export PATH="$$HOME/.foundry/bin:$$PATH"; forge fmt --check --root evm

.PHONY: evm-test
evm-test: ## forge test for evm/. Not part of `make test`.
	@export PATH="$$HOME/.foundry/bin:$$PATH"; forge test --root evm

.PHONY: deny
deny: ## cargo deny: licences, sources and advisories (deny.toml)
	@cargo deny check

.PHONY: evm-script-test
evm-script-test: ## Stubbed runs of evm/script/deploy.sh (resume, verification) and drift.sh. Not part of `make test`.
	@bash evm/script/deploy_resume_test.sh
	@bash evm/script/drift_test.sh

.PHONY: clean
clean: ## Clean cargo + contract/data-driver target dirs
	@cargo clean
	@rm -rf target/contract target/data-driver

.PHONY: help
help: ## Show this help message
	@echo "Atlas workspace Makefile — registry contract, host types, test proxy"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
