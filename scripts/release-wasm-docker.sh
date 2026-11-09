#!/usr/bin/env bash
# Build the deploy WASM the way CI does, from the committed tree, in a Linux
# amd64 container. A macOS build is not byte-identical to the Linux one (the
# compiler orders functions differently), so deploy the Linux artifact: this
# script's output or the CI `release-wasm` artifact. Both print the same hash.
#
# Needs: docker (OrbStack works), git. Builds HEAD of the checkout; commit first.
# Output: target/release-docker/atlas.wasm and its sha256 on stdout.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "release-wasm-docker: uncommitted changes; this builds HEAD only" >&2
  exit 1
fi

# Keep in step with .github/workflows/ci.yml.
BINARYEN_URL="https://github.com/WebAssembly/binaryen/releases/download/version_116/binaryen-version_116-x86_64-linux.tar.gz"
BINARYEN_SHA256="c55b74f3109cdae97490faf089b0286d3bba926bb6ea5ed00c8c784fc53718fd"

# Pinned by digest: the toolchain is installed by rustup at 1.94.0 and binaryen
# is checksummed, so the WASM does not depend on the image, but nothing should
# be left floating in a deploy path.
IMAGE="rust@sha256:f17e723020f87c1b4ac4ff6d73c9dfbb7d5cb978754c76641e47337d65f61e12"

commit="$(git rev-parse HEAD)"
out="$ROOT/target/release-docker"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src"
# A stale file from an earlier run must never look like this run's output.
rm -rf "$out"
mkdir -p "$out"
git archive HEAD | tar -x -C "$work/src"
echo "commit:   $commit"

docker run --rm --platform linux/amd64 \
  -e BINARYEN_URL="$BINARYEN_URL" -e BINARYEN_SHA256="$BINARYEN_SHA256" \
  -v "$work/src":/src:ro -v "$out":/out \
  "$IMAGE" bash -euo pipefail -c '
    apt-get update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq make curl >/dev/null 2>&1
    export HOME=/home/runner
    mkdir -p "$HOME/work" && cp -r /src "$HOME/work/atlas" && cd "$HOME/work/atlas"
    curl -sSfL -o /tmp/binaryen.tar.gz "$BINARYEN_URL"
    echo "$BINARYEN_SHA256  /tmp/binaryen.tar.gz" | sha256sum -c - >/dev/null
    tar -xzf /tmp/binaryen.tar.gz -C /tmp
    export PATH=/tmp/binaryen-version_116/bin:$PATH
    rustup toolchain install 1.94.0 --profile minimal --target wasm32-unknown-unknown -c rust-src >/dev/null 2>&1
    make release-wasm
    cp target/contract/wasm32-unknown-unknown/release/atlas.wasm /out/atlas.wasm
  ' | tee "$work/build.log" | grep -E "^(wasm-opt|size|sha256):"

# Re-hash on the host. The container's printed hash is not the file we deploy.
[[ -s "$out/atlas.wasm" ]] || { echo "release-wasm-docker: no atlas.wasm was produced" >&2; exit 1; }
host_hash="$(shasum -a 256 "$out/atlas.wasm" | cut -d' ' -f1)"
printed_hash="$(sed -n 's/^sha256: *//p' "$work/build.log")"
if [[ "$host_hash" != "$printed_hash" ]]; then
  echo "release-wasm-docker: host hash $host_hash != container hash $printed_hash" >&2
  exit 1
fi
(cd "$out" && shasum -a 256 atlas.wasm >SHA256SUMS)
echo "host:     $host_hash  ($out/atlas.wasm)"
