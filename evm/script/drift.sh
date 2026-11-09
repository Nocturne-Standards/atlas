#!/usr/bin/env bash
# Read-only. Compare an export cache to EvmAtlas at the block the file
# records, and to the latest block. For kind 2, unaliasedSender must equal
# the last 20 bytes of keccak256 of the raw id.
#
# When DUSK_ATLAS_ID is set, each kind 2 name is also read from Dusk Atlas
# `resolve` and must be the same 32 bytes. This script does not send
# transactions.
#
# Also checks what a consumer actually trusts: the RPC chain id equals the
# cache, the cache lists services, the directory guardian is the cached warden
# and the warden points back at the directory, and nothing is pending. A
# pending directory change, warden admin change, or warden repoint is reported
# as a failure (exit 1): it is the early warning that something is about to
# move. DRIFT_ALLOW_PENDING=1 downgrades that to a notice.
#
# Required: ATLAS_RPC_URL, ATLAS_EXPORT.
# Optional: DUSK_ATLAS_ID, DUSK_RUES_URL (default testnet nodes),
#           DRIFT_ALLOW_PENDING.
set -euo pipefail

export PATH="${HOME}/.foundry/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVM="$(cd "$(dirname "$0")/.." && pwd)"

: "${ATLAS_RPC_URL:?set ATLAS_RPC_URL}"
: "${ATLAS_EXPORT:?set ATLAS_EXPORT}"
[[ -f "$ATLAS_EXPORT" ]] || {
  echo "drift.sh: export not found: $ATLAS_EXPORT" >&2
  exit 1
}

atlas="$(jq -r '.atlas' "$ATLAS_EXPORT")"
warden="$(jq -r '.warden' "$ATLAS_EXPORT")"
file_chain="$(jq -r '.chainId' "$ATLAS_EXPORT")"
file_block="$(jq -r '.block' "$ATLAS_EXPORT")"
DUSK_RUES_URL="${DUSK_RUES_URL:-https://testnet.nodes.dusk.network}"

fail=0

lc() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

note_pending() {
  if [[ "${DRIFT_ALLOW_PENDING:-0}" == 1 ]]; then
    echo "drift.sh: notice: $1" >&2
  else
    echo "drift.sh: PENDING: $1" >&2
    fail=1
  fi
}

live_chain="$(cast chain-id --rpc-url "$ATLAS_RPC_URL")"
if [[ "$live_chain" != "$file_chain" ]]; then
  echo "drift.sh: RPC chain id ${live_chain} != cache chainId ${file_chain}" >&2
  exit 1
fi
if [[ "$(jq '.services | length' "$ATLAS_EXPORT")" -eq 0 ]]; then
  echo "drift.sh: the cache lists no services; nothing to compare" >&2
  exit 1
fi
atlas_code="$(cast code "$atlas" --rpc-url "$ATLAS_RPC_URL")"
if [[ -z "$atlas_code" || "$atlas_code" == "0x" ]]; then
  echo "drift.sh: no contract at ${atlas}" >&2
  exit 1
fi

got="$(cast call "$atlas" "guardian()(address)" --rpc-url "$ATLAS_RPC_URL")"
if [[ "$(lc "$got")" != "$(lc "$warden")" ]]; then
  echo "drift.sh: directory guardian ${got} != cached warden ${warden}" >&2
  fail=1
fi
got="$(cast call "$warden" "atlas()(address)" --rpc-url "$ATLAS_RPC_URL")"
if [[ "$(lc "$got")" != "$(lc "$atlas")" ]]; then
  echo "drift.sh: warden.atlas() ${got} != cached directory ${atlas}" >&2
  fail=1
fi
echo "drift.sh: scheduler $(cast call "$warden" "scheduler()(address)" --rpc-url "$ATLAS_RPC_URL")" \
  "warden delay $(cast call "$warden" "delayBlocks()(uint64)" --rpc-url "$ATLAS_RPC_URL")" \
  "directory timelock $(cast call "$atlas" "timelockBlocks()(uint64)" --rpc-url "$ATLAS_RPC_URL")"

dir_pending="$(cast call "$atlas" "pending()(uint8,address,uint64,uint64)" --rpc-url "$ATLAS_RPC_URL" --json)"
if [[ "$(jq -r '.[0]' <<<"$dir_pending")" != 0 ]]; then
  note_pending "the directory has a pending change: ${dir_pending}"
fi
admin_pending="$(cast call "$warden" "pendingAdmin()(uint8,address,uint64,uint64)" --rpc-url "$ATLAS_RPC_URL" --json)"
if [[ "$(jq -r '.[0]' <<<"$admin_pending")" != 0 ]]; then
  note_pending "the warden has a pending admin change: ${admin_pending}"
fi
check_block() {
  local label="$1" block_arg="$2" name="$3" kind="$4" data="$5"
  local name32 read_json got_kind got_data
  name32="$(cast format-bytes32-string "$name")"
  if [[ -n "$block_arg" ]]; then
    read_json="$(cast call "$atlas" "resolve(bytes32)(uint8,bytes32)" "$name32" \
      --rpc-url "$ATLAS_RPC_URL" --block "$block_arg" --json)"
  else
    read_json="$(cast call "$atlas" "resolve(bytes32)(uint8,bytes32)" "$name32" \
      --rpc-url "$ATLAS_RPC_URL" --json)"
  fi
  got_kind="$(jq -r '.[0]' <<<"$read_json")"
  got_data="$(jq -r '.[1]' <<<"$read_json")"
  if [[ "$got_kind" != "$kind" || "$(printf '%s' "$got_data" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$data" | tr '[:upper:]' '[:lower:]')" ]]; then
    echo "drift.sh: ${label} ${name} kind ${got_kind} data ${got_data} != file kind ${kind} data ${data}" >&2
    fail=1
  fi
}

sender_of() {
  local data="$1" hash
  hash="$(cast keccak "$data")"
  echo "0x${hash: -40}"
}

while IFS= read -r row; do
  name="$(jq -r '.name' <<<"$row")"
  kind="$(jq -r '.kind' <<<"$row")"
  data="$(jq -r '.data' <<<"$row")"
  check_block "block ${file_block}" "$file_block" "$name" "$kind" "$data"
  check_block "latest" "" "$name" "$kind" "$data"
  svc_pending="$(cast call "$warden" "pendingService(bytes32)(bool,uint8,bytes32,uint64)" \
    "$(cast format-bytes32-string "$name")" --rpc-url "$ATLAS_RPC_URL" --json)"
  if [[ "$(lc "$(jq -r '.[0]' <<<"$svc_pending")")" == "true" ]]; then
    note_pending "the warden has a pending repoint for ${name}: ${svc_pending}"
  fi
  if [[ "$kind" == 2 ]]; then
    name32="$(cast format-bytes32-string "$name")"
    got="$(cast call "$atlas" "unaliasedSender(bytes32)(address)" "$name32" --rpc-url "$ATLAS_RPC_URL")"
    expect="$(sender_of "$data")"
    if [[ "$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$expect" | tr '[:upper:]' '[:lower:]')" ]]; then
      echo "drift.sh: unaliasedSender ${name} ${got} != ${expect}" >&2
      fail=1
    fi
  fi
done < <(jq -c '.services[]' "$ATLAS_EXPORT")

if [[ -n "${DUSK_ATLAS_ID:-}" ]]; then
  bin="${ROOT}/target/debug/examples/resolve_arg"
  cargo build -p nocturne-atlas-encoding --example resolve_arg --manifest-path "${ROOT}/Cargo.toml" >/dev/null
  dusk_id="${DUSK_ATLAS_ID#0x}"
  body=""
  resp=""
  cleanup() { rm -f "$body" "$resp"; }
  trap cleanup EXIT
  while IFS= read -r row; do
    kind="$(jq -r '.kind' <<<"$row")"
    [[ "$kind" == 2 ]] || continue
    name="$(jq -r '.name' <<<"$row")"
    data="$(jq -r '.data' <<<"$row")"
    arg_hex="$("$bin" encode "$name")"
    rm -f "$body" "$resp"
    body="$(mktemp)"
    python3 -c 'import sys,binascii; open(sys.argv[1],"wb").write(binascii.unhexlify(sys.argv[2]))' "$body" "$arg_hex"
    resp="$(mktemp)"
    code="$(curl -sS -o "$resp" -w '%{http_code}' -X POST \
      -H 'content-type: application/octet-stream' \
      -H 'rusk-version: 1.0.0' \
      --data-binary @"$body" \
      "${DUSK_RUES_URL%/}/on/contracts:${dusk_id}/resolve")"
    if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
      echo "drift.sh: dusk resolve ${name} HTTP ${code}" >&2
      fail=1
      continue
    fi
    resp_hex="$(python3 -c 'import sys,binascii; print(binascii.hexlify(open(sys.argv[1],"rb").read()).decode())' "$resp")"
    got="$("$bin" decode <<<"$resp_hex")"
    want="$(printf '%s' "${data#0x}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$got" == none ]]; then
      echo "drift.sh: dusk resolve ${name} is missing" >&2
      fail=1
    elif [[ "$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')" != "$want" ]]; then
      echo "drift.sh: dusk resolve ${name} ${got} != ${want}" >&2
      fail=1
    fi
  done < <(jq -c '.services[]' "$ATLAS_EXPORT")
else
  echo "drift.sh: DUSK_ATLAS_ID unset, skipped dusk compare" >&2
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "drift.sh: ok atlas ${atlas} block ${file_block}"
