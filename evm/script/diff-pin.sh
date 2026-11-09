#!/usr/bin/env bash
# Read-only. Compare a lending pin to EvmAtlas. Does not send transactions.
#
# Address names must match resolveAddress. Native names must match
# resolveNativeId, and unaliasedSender must match the pin's derived sender.
# Morpho is not a directory name and is not read.
#
# Required: ATLAS_RPC_URL, ATLAS_ADDRESS, ATLAS_PIN.
set -euo pipefail

export PATH="${HOME}/.foundry/bin:${PATH}"

: "${ATLAS_RPC_URL:?set ATLAS_RPC_URL}"
: "${ATLAS_ADDRESS:?set ATLAS_ADDRESS}"
: "${ATLAS_PIN:?set ATLAS_PIN}"
[[ -f "$ATLAS_PIN" ]] || {
  echo "diff-pin.sh: pin not found: $ATLAS_PIN" >&2
  exit 1
}

fail=0

lc() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

pin_get() {
  jq -r "$1" "$ATLAS_PIN"
}

resolve_of() {
  local name="$1" name32
  name32="$(cast format-bytes32-string "$name")"
  cast call "$ATLAS_ADDRESS" "resolve(bytes32)(uint8,bytes32)" "$name32" \
    --rpc-url "$ATLAS_RPC_URL" --json
}

check_sender() {
  local name="$1" expr="$2" want name32 got
  want="$(pin_get "$expr")"
  if [[ -z "$want" || "$want" == null ]]; then
    return
  fi
  name32="$(cast format-bytes32-string "$name")"
  got="$(cast call "$ATLAS_ADDRESS" "unaliasedSender(bytes32)(address)" "$name32" --rpc-url "$ATLAS_RPC_URL")"
  if [[ "$(lc "$got")" != "$(lc "$want")" ]]; then
    echo "diff-pin.sh: ${name} unaliasedSender ${got} != pin ${expr} ${want}" >&2
    fail=1
  fi
}

check_address() {
  local name="$1" expr="$2" want json kind data got
  want="$(pin_get "$expr")"
  if [[ -z "$want" || "$want" == null ]]; then
    echo "diff-pin.sh: pin missing ${expr} for ${name}" >&2
    fail=1
    return
  fi
  json="$(resolve_of "$name")"
  kind="$(jq -r '.[0]' <<<"$json")"
  data="$(jq -r '.[1]' <<<"$json")"
  got="0x${data: -40}"
  if [[ "$kind" != 1 || "$(lc "$got")" != "$(lc "$want")" ]]; then
    echo "diff-pin.sh: ${name} kind ${kind} data ${data} != pin ${want}" >&2
    fail=1
  fi
}

check_native() {
  local name="$1" id_expr="$2" sender_expr="$3"
  local want_id want_sender json kind data got_id got_sender name32
  want_id="$(pin_get "$id_expr")"
  want_sender="$(pin_get "$sender_expr")"
  if [[ -z "$want_id" || "$want_id" == null || -z "$want_sender" || "$want_sender" == null ]]; then
    echo "diff-pin.sh: pin missing ${name} id or sender" >&2
    fail=1
    return
  fi
  json="$(resolve_of "$name")"
  kind="$(jq -r '.[0]' <<<"$json")"
  data="$(jq -r '.[1]' <<<"$json")"
  got_id="${data#0x}"
  want_id="${want_id#0x}"
  want_id="${want_id#0X}"
  name32="$(cast format-bytes32-string "$name")"
  got_sender="$(cast call "$ATLAS_ADDRESS" "unaliasedSender(bytes32)(address)" "$name32" --rpc-url "$ATLAS_RPC_URL")"
  if [[ "$kind" != 2 || "$(lc "$got_id")" != "$(lc "$want_id")" || "$(lc "$got_sender")" != "$(lc "$want_sender")" ]]; then
    echo "diff-pin.sh: ${name} kind ${kind} id ${data} sender ${got_sender} != pin id ${want_id} sender ${want_sender}" >&2
    fail=1
  fi
}

check_address "evm.sound.compliance-gate" '.contracts.compliance_gate_evm'
check_address "evm.sound.router" '.contracts.compliance_morpho_router'
check_address "evm.sound.disposal-rounds" '.contracts.disposal_rounds'
check_address "evm.sound.nav-receiver" '.contracts.nav_receiver'
check_address "evm.sound.oracle" '.test_market.oracle'
check_native "native.attested-nav" '.latch_native.attested_nav_contract_id' '.latch_native.attested_nav_unaliased_evm'
check_native "native.address-link-registry" '.latch_native.address_link_registry_contract_id' '.latch_native.address_link_registry_unaliased_evm'
check_native "native.compliance-gate" '.latch_native.compliance_gate_contract_id' '.latch_native.compliance_gate_unaliased_evm'
check_sender "native.attested-nav" '.config.trusted_nav_native_sender'
check_sender "native.address-link-registry" '.config.trusted_link_native_sender'
check_sender "native.compliance-gate" '.config.trusted_native_sender'

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "diff-pin.sh: ok ${ATLAS_ADDRESS} (morpho left on the pin)"
