#!/usr/bin/env bash
# Deploy EvmAtlas, deploy EvmWarden against it, initGuardian(warden), then
# schedule each manifest row through the warden. The cache is written as soon
# as initGuardian lands, and updated after each row that resolve can read back.
#
# Needs: forge, cast (Foundry), jq, python3. The key never goes on the command
# line. Production uses a keystore:
#   ATLAS_KEYSTORE=/path/to/key ATLAS_PASSWORD_FILE=/path/to/password
# or a Foundry account name:
#   ATLAS_ACCOUNT=atlas ATLAS_PASSWORD_FILE=/path/to/password
# Anvil and other unlocked nodes:
#   ATLAS_UNLOCKED=1 ATLAS_FROM=0x...
#
# The deployer signs the creates and initGuardian. The scheduler signs
# scheduleService. When that is the same key, one auth is enough. When it is
# not, set one of:
#   ATLAS_SCHEDULER_UNLOCKED=1
#   ATLAS_SCHEDULER_KEYSTORE + ATLAS_SCHEDULER_PASSWORD_FILE
#   ATLAS_SCHEDULER_ACCOUNT + ATLAS_SCHEDULER_PASSWORD_FILE
#
# PRIVATE_KEY is ignored on purpose.
#
# Required: ATLAS_RPC_URL, ATLAS_SCHEDULER, ATLAS_WARDEN_DELAY,
# ATLAS_TIMELOCK_BLOCKS (> 0, <= 3888000, and >= ATLAS_WARDEN_DELAY; the
# warden keeps that relation afterwards, see EvmWarden setDelay/setTimelock),
# ATLAS_MANIFEST. ATLAS_CHAIN_ID defaults to 745 and must match the RPC.
# ATLAS_EXPORT is the cache path (default: evm/deployments/cache.json).
#
# A failed setService used to leave a deployed directory with no cache.
# Re-run with ATLAS_ADDRESS set to that directory. The script skips create
# and initGuardian. A row whose resolve already matches is recorded and not
# scheduled again. A row already pending with the same locator is not
# scheduled again; it is executed only after the delay. If any row is still
# waiting, the script exits 1 and the cache does not list it.
set -euo pipefail

export PATH="${HOME}/.foundry/bin:${PATH}"

for cmd in forge cast jq python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "deploy.sh: ${cmd} is required" >&2
    exit 1
  fi
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 90 days of ~2-second DuskEVM blocks. Matches EvmAtlas.MAX_TIMELOCK_BLOCKS.
MAX_TIMELOCK_BLOCKS=3888000

if [[ -n "${PRIVATE_KEY:-}${ATLAS_PRIVATE_KEY:-}" ]]; then
  echo "deploy.sh: PRIVATE_KEY is set and will not be used. Use a keystore." >&2
fi

: "${ATLAS_RPC_URL:?set ATLAS_RPC_URL}"
: "${ATLAS_SCHEDULER:?set ATLAS_SCHEDULER}"
: "${ATLAS_WARDEN_DELAY:?set ATLAS_WARDEN_DELAY}"
: "${ATLAS_TIMELOCK_BLOCKS:?set ATLAS_TIMELOCK_BLOCKS}"
: "${ATLAS_MANIFEST:?set ATLAS_MANIFEST}"
ATLAS_CHAIN_ID="${ATLAS_CHAIN_ID:-745}"
ATLAS_EXPORT="${ATLAS_EXPORT:-${ROOT}/deployments/cache.json}"

if [[ ! "$ATLAS_TIMELOCK_BLOCKS" =~ ^[0-9]+$ ]] || [[ "$ATLAS_TIMELOCK_BLOCKS" -eq 0 ]]; then
  echo "deploy.sh: ATLAS_TIMELOCK_BLOCKS must be an integer greater than 0" >&2
  exit 1
fi
if [[ "$ATLAS_TIMELOCK_BLOCKS" -gt "$MAX_TIMELOCK_BLOCKS" ]]; then
  echo "deploy.sh: ATLAS_TIMELOCK_BLOCKS ${ATLAS_TIMELOCK_BLOCKS} exceeds MAX_TIMELOCK_BLOCKS ${MAX_TIMELOCK_BLOCKS}" >&2
  exit 1
fi
if [[ ! "$ATLAS_WARDEN_DELAY" =~ ^[0-9]+$ ]]; then
  echo "deploy.sh: ATLAS_WARDEN_DELAY must be an integer" >&2
  exit 1
fi
if [[ "$ATLAS_WARDEN_DELAY" -gt "$MAX_TIMELOCK_BLOCKS" ]]; then
  echo "deploy.sh: ATLAS_WARDEN_DELAY ${ATLAS_WARDEN_DELAY} exceeds MAX_TIMELOCK_BLOCKS ${MAX_TIMELOCK_BLOCKS}" >&2
  exit 1
fi
if [[ "$ATLAS_TIMELOCK_BLOCKS" -lt "$ATLAS_WARDEN_DELAY" ]]; then
  echo "deploy.sh: ATLAS_TIMELOCK_BLOCKS ${ATLAS_TIMELOCK_BLOCKS} is below the warden delay ${ATLAS_WARDEN_DELAY}" >&2
  exit 1
fi
scheduler_lc="$(printf '%s' "$ATLAS_SCHEDULER" | tr '[:upper:]' '[:lower:]')"
if [[ ! "$ATLAS_SCHEDULER" =~ ^0[xX][0-9a-fA-F]{40}$ ]] || [[ "$scheduler_lc" == "0x0000000000000000000000000000000000000000" ]]; then
  echo "deploy.sh: ATLAS_SCHEDULER must be a non-zero address" >&2
  exit 1
fi
if [[ -n "${ATLAS_ADDRESS:-}" ]] && [[ ! "$ATLAS_ADDRESS" =~ ^0[xX][0-9a-fA-F]{40}$ ]]; then
  echo "deploy.sh: ATLAS_ADDRESS must be a 20-byte address" >&2
  exit 1
fi
if [[ ! -f "$ATLAS_MANIFEST" ]]; then
  echo "deploy.sh: manifest not found: $ATLAS_MANIFEST" >&2
  exit 1
fi

# A real deployment builds the contracts from a known commit. Anvil and other
# unlocked nodes (tests, local runs) skip this.
if [[ "${ATLAS_UNLOCKED:-0}" != 1 && "${ATLAS_ALLOW_DIRTY:-0}" != 1 ]]; then
  if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    echo "deploy.sh: the working tree has uncommitted changes. Deploy from a clean checkout of the release commit, or set ATLAS_ALLOW_DIRTY=1." >&2
    exit 1
  fi
fi
echo "deploy.sh: building commit $(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"

auth=()
if [[ "${ATLAS_UNLOCKED:-0}" == 1 ]]; then
  : "${ATLAS_FROM:?set ATLAS_FROM when ATLAS_UNLOCKED=1}"
  auth=(--unlocked --from "$ATLAS_FROM")
elif [[ -n "${ATLAS_KEYSTORE:-}" ]]; then
  : "${ATLAS_PASSWORD_FILE:?set ATLAS_PASSWORD_FILE}"
  [[ -f "$ATLAS_PASSWORD_FILE" ]] || {
    echo "deploy.sh: password file not found" >&2
    exit 1
  }
  auth=(--keystore "$ATLAS_KEYSTORE" --password-file "$ATLAS_PASSWORD_FILE")
else
  : "${ATLAS_ACCOUNT:?set ATLAS_ACCOUNT or ATLAS_KEYSTORE}"
  : "${ATLAS_PASSWORD_FILE:?set ATLAS_PASSWORD_FILE}"
  [[ -f "$ATLAS_PASSWORD_FILE" ]] || {
    echo "deploy.sh: password file not found" >&2
    exit 1
  }
  auth=(--account "$ATLAS_ACCOUNT" --password-file "$ATLAS_PASSWORD_FILE")
fi

if [[ "${ATLAS_UNLOCKED:-0}" == 1 ]]; then
  signer="$ATLAS_FROM"
else
  signer="$(cast wallet address "${auth[@]}")"
fi
signer_lc="$(printf '%s' "$signer" | tr '[:upper:]' '[:lower:]')"

scheduler_auth=()
if [[ "$signer_lc" == "$scheduler_lc" ]]; then
  scheduler_auth=("${auth[@]}")
elif [[ "${ATLAS_SCHEDULER_UNLOCKED:-0}" == 1 ]]; then
  scheduler_auth=(--unlocked --from "$ATLAS_SCHEDULER")
elif [[ -n "${ATLAS_SCHEDULER_KEYSTORE:-}" ]]; then
  : "${ATLAS_SCHEDULER_PASSWORD_FILE:?set ATLAS_SCHEDULER_PASSWORD_FILE}"
  [[ -f "$ATLAS_SCHEDULER_PASSWORD_FILE" ]] || {
    echo "deploy.sh: scheduler password file not found" >&2
    exit 1
  }
  scheduler_auth=(--keystore "$ATLAS_SCHEDULER_KEYSTORE" --password-file "$ATLAS_SCHEDULER_PASSWORD_FILE")
elif [[ -n "${ATLAS_SCHEDULER_ACCOUNT:-}" ]]; then
  : "${ATLAS_SCHEDULER_PASSWORD_FILE:?set ATLAS_SCHEDULER_PASSWORD_FILE}"
  [[ -f "$ATLAS_SCHEDULER_PASSWORD_FILE" ]] || {
    echo "deploy.sh: scheduler password file not found" >&2
    exit 1
  }
  scheduler_auth=(--account "$ATLAS_SCHEDULER_ACCOUNT" --password-file "$ATLAS_SCHEDULER_PASSWORD_FILE")
else
  echo "deploy.sh: deployer ${signer} is not ATLAS_SCHEDULER. Set ATLAS_SCHEDULER_UNLOCKED, ATLAS_SCHEDULER_KEYSTORE, or ATLAS_SCHEDULER_ACCOUNT so scheduleService is signed by the scheduler." >&2
  exit 1
fi
if [[ "$signer_lc" != "$scheduler_lc" && "${ATLAS_SCHEDULER_UNLOCKED:-0}" != 1 ]]; then
  ssigner="$(cast wallet address "${scheduler_auth[@]}")"
  ssigner_lc="$(printf '%s' "$ssigner" | tr '[:upper:]' '[:lower:]')"
  if [[ "$ssigner_lc" != "$scheduler_lc" ]]; then
    echo "deploy.sh: scheduler signer ${ssigner} != ATLAS_SCHEDULER ${ATLAS_SCHEDULER}" >&2
    exit 1
  fi
fi

live_chain="$(cast chain-id --rpc-url "$ATLAS_RPC_URL")"
if [[ "$live_chain" != "$ATLAS_CHAIN_ID" ]]; then
  echo "deploy.sh: RPC chain id ${live_chain} != ATLAS_CHAIN_ID ${ATLAS_CHAIN_ID}" >&2
  exit 1
fi

rows=()
while IFS= read -r row; do
  rows+=("$row")
done < <(jq -c '.services[]' "$ATLAS_MANIFEST")
if [[ "${#rows[@]}" -eq 0 ]]; then
  echo "deploy.sh: manifest has no services" >&2
  exit 1
fi

read_block="$(cast block-number --rpc-url "$ATLAS_RPC_URL")"
declare -a names kinds datas
for row in "${rows[@]}"; do
  name="$(jq -r '.name' <<<"$row")"
  kind="$(jq -r '.kind' <<<"$row")"
  if [[ ! "$name" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]{0,31}$ ]]; then
    echo "deploy.sh: service name '${name}' must be 1..32 characters of A-Z a-z 0-9 . _ - and not start with '-'" >&2
    exit 1
  fi
  name32="$(cast format-bytes32-string "$name")"
  if [[ "$kind" == 1 ]]; then
    addr="$(jq -r '.address' <<<"$row")"
    if [[ ! "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
      echo "deploy.sh: ${name} address must match ^0x[0-9a-fA-F]{40}$" >&2
      exit 1
    fi
    code="$(cast code "$addr" --rpc-url "$ATLAS_RPC_URL" --block "$read_block")"
    if [[ -z "$code" || "$code" == "0x" ]]; then
      echo "deploy.sh: no code at ${addr} for ${name} at block ${read_block}" >&2
      exit 1
    fi
    data="$(python3 -c 'import sys; a=sys.argv[1].lower();
a=a[2:] if a.startswith("0x") else a
print("0x"+"0"*(64-len(a))+a)' "$addr")"
  elif [[ "$kind" == 2 ]]; then
    data="$(jq -r '.id' <<<"$row")"
    bare="${data#0x}"
    bare="${bare#0X}"
    if [[ ! "$bare" =~ ^[0-9a-fA-F]{64}$ || "$bare" =~ ^0{64}$ ]]; then
      echo "deploy.sh: ${name} needs a non-zero 32-byte id" >&2
      exit 1
    fi
    data="0x$(echo "$bare" | tr '[:upper:]' '[:lower:]')"
  else
    echo "deploy.sh: ${name} kind must be 1 or 2" >&2
    exit 1
  fi
  names+=("$name32")
  kinds+=("$kind")
  datas+=("$data")
done

dups="$(printf '%s\n' "${names[@]}" | sort | uniq -d)"
if [[ -n "$dups" ]]; then
  echo "deploy.sh: the manifest names a service more than once" >&2
  exit 1
fi

lc() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# cast prints large integers as "3888000 [3.888e6]". Keep the first field.
num() {
  awk '{print $1}' <<<"$1"
}

ZERO_ADDRESS=0x0000000000000000000000000000000000000000

write_cache() {
  mkdir -p "$(dirname "$ATLAS_EXPORT")"
  # Atomic: an aborted run never leaves a half-written cache.
  printf '%s\n' "$cache" >"${ATLAS_EXPORT}.tmp.$$"
  mv "${ATLAS_EXPORT}.tmp.$$" "$ATLAS_EXPORT"
  echo "deploy.sh: cache ${ATLAS_EXPORT} atlas ${atlas} warden ${warden} block ${block}"
}

# initGuardian has no acceptance step, so the address it names is final: a
# wrong warden would hold the directory for good. Check the warden against this
# run's values before every initGuardian, not only afterwards in verify_pair.
verify_warden() {
  local w="$1" got code
  code="$(cast code "$w" --rpc-url "$ATLAS_RPC_URL")"
  if [[ -z "$code" || "$code" == "0x" ]]; then
    echo "deploy.sh: no contract at warden ${w}; initGuardian not sent" >&2
    exit 1
  fi
  got="$(cast call "$w" "atlas()(address)" --rpc-url "$ATLAS_RPC_URL")"
  [[ "$(lc "$got")" == "$(lc "$atlas")" ]] || { echo "deploy.sh: warden.atlas() ${got} != ${atlas}; initGuardian not sent" >&2; exit 1; }
  got="$(num "$(cast call "$w" "chainId()(uint256)" --rpc-url "$ATLAS_RPC_URL")")"
  [[ "$got" == "$ATLAS_CHAIN_ID" ]] || { echo "deploy.sh: warden chainId ${got} != ${ATLAS_CHAIN_ID}; initGuardian not sent" >&2; exit 1; }
  got="$(cast call "$w" "scheduler()(address)" --rpc-url "$ATLAS_RPC_URL")"
  [[ "$(lc "$got")" == "$scheduler_lc" ]] || { echo "deploy.sh: warden scheduler ${got} != ATLAS_SCHEDULER ${ATLAS_SCHEDULER}; initGuardian not sent" >&2; exit 1; }
  got="$(num "$(cast call "$w" "delayBlocks()(uint64)" --rpc-url "$ATLAS_RPC_URL")")"
  [[ "$got" == "$ATLAS_WARDEN_DELAY" ]] || { echo "deploy.sh: warden delayBlocks ${got} != ATLAS_WARDEN_DELAY ${ATLAS_WARDEN_DELAY}; initGuardian not sent" >&2; exit 1; }
}

if [[ -n "${ATLAS_ADDRESS:-}" ]]; then
  atlas="$ATLAS_ADDRESS"
  atlas_code="$(cast code "$atlas" --rpc-url "$ATLAS_RPC_URL")"
  if [[ -z "$atlas_code" || "$atlas_code" == "0x" ]]; then
    echo "deploy.sh: no contract at ATLAS_ADDRESS ${atlas}" >&2
    exit 1
  fi
  warden="$(cast call "$atlas" "guardian()(address)" --rpc-url "$ATLAS_RPC_URL")"
  if [[ "$(lc "$warden")" == "$ZERO_ADDRESS" ]]; then
    # initGuardian never landed on an earlier run. Finish it for the warden
    # that run created, if the caller names it and signs as the deployer.
    if [[ -z "${ATLAS_WARDEN:-}" ]]; then
      echo "deploy.sh: ${atlas} has no guardian: initGuardian did not land. Re-run with ATLAS_WARDEN set to the warden the failed run printed." >&2
      exit 1
    fi
    if [[ ! "$ATLAS_WARDEN" =~ ^0[xX][0-9a-fA-F]{40}$ ]]; then
      echo "deploy.sh: ATLAS_WARDEN must be a 20-byte address" >&2
      exit 1
    fi
    atlas_deployer="$(cast call "$atlas" "deployer()(address)" --rpc-url "$ATLAS_RPC_URL")"
    if [[ "$(lc "$atlas_deployer")" != "$signer_lc" ]]; then
      echo "deploy.sh: only the directory deployer ${atlas_deployer} can call initGuardian; the signer is ${signer}" >&2
      exit 1
    fi
    warden="$ATLAS_WARDEN"
    verify_warden "$warden"
    echo "deploy.sh: finishing initGuardian(${warden}, ${ATLAS_TIMELOCK_BLOCKS}) on ${atlas}"
    cast send "$atlas" "initGuardian(address,uint64)" "$warden" "$ATLAS_TIMELOCK_BLOCKS" \
      --rpc-url "$ATLAS_RPC_URL" "${auth[@]}" >/dev/null
  fi
  echo "deploy.sh: resuming directory ${atlas} guardian ${warden}"
else
  echo "deploy.sh: deploying EvmAtlas on chain ${ATLAS_CHAIN_ID}"
  deploy_json="$(forge create src/EvmAtlas.sol:EvmAtlas \
    --rpc-url "$ATLAS_RPC_URL" \
    --broadcast \
    --json \
    "${auth[@]}" \
    --constructor-args "$ATLAS_CHAIN_ID")"
  atlas="$(jq -r '.deployedTo' <<<"$deploy_json")"
  if [[ ! "$atlas" =~ ^0[xX][0-9a-fA-F]{40}$ ]]; then
    echo "deploy.sh: forge create did not return an atlas address" >&2
    echo "$deploy_json" >&2
    exit 1
  fi

  echo "deploy.sh: deploying EvmWarden for ${atlas}"
  warden_json="$(forge create src/EvmWarden.sol:EvmWarden \
    --rpc-url "$ATLAS_RPC_URL" \
    --broadcast \
    --json \
    "${auth[@]}" \
    --constructor-args "$ATLAS_CHAIN_ID" "$atlas" "$ATLAS_SCHEDULER" "$ATLAS_WARDEN_DELAY")"
  warden="$(jq -r '.deployedTo' <<<"$warden_json")"
  if [[ ! "$warden" =~ ^0[xX][0-9a-fA-F]{40}$ ]]; then
    echo "deploy.sh: forge create did not return a warden address" >&2
    echo "$warden_json" >&2
    exit 1
  fi

  echo "deploy.sh: EvmWarden ${warden}. If initGuardian fails, resume with ATLAS_ADDRESS=${atlas} ATLAS_WARDEN=${warden}"
  verify_warden "$warden"
  cast send "$atlas" "initGuardian(address,uint64)" "$warden" "$ATLAS_TIMELOCK_BLOCKS" \
    --rpc-url "$ATLAS_RPC_URL" "${auth[@]}" >/dev/null
fi

# Nothing is cached, and no service is scheduled, until the pair checks out
# against the values this run was given. This is what keeps a mistyped
# ATLAS_ADDRESS from being recorded as the deployment.
verify_pair() {
  local got
  got="$(num "$(cast call "$atlas" "chainId()(uint256)" --rpc-url "$ATLAS_RPC_URL")")"
  [[ "$got" == "$ATLAS_CHAIN_ID" ]] || { echo "deploy.sh: directory chainId ${got} != ${ATLAS_CHAIN_ID}" >&2; exit 1; }
  got="$(cast call "$atlas" "guardian()(address)" --rpc-url "$ATLAS_RPC_URL")"
  if [[ "$(lc "$got")" == "$ZERO_ADDRESS" || "$(lc "$got")" != "$(lc "$warden")" ]]; then
    echo "deploy.sh: directory guardian ${got} is not the warden ${warden}" >&2
    exit 1
  fi
  got="$(cast call "$warden" "atlas()(address)" --rpc-url "$ATLAS_RPC_URL")"
  [[ "$(lc "$got")" == "$(lc "$atlas")" ]] || { echo "deploy.sh: warden.atlas() ${got} != ${atlas}" >&2; exit 1; }
  got="$(cast call "$warden" "scheduler()(address)" --rpc-url "$ATLAS_RPC_URL")"
  [[ "$(lc "$got")" == "$scheduler_lc" ]] || { echo "deploy.sh: warden scheduler ${got} != ATLAS_SCHEDULER ${ATLAS_SCHEDULER}" >&2; exit 1; }
  got="$(num "$(cast call "$warden" "delayBlocks()(uint64)" --rpc-url "$ATLAS_RPC_URL")")"
  [[ "$got" == "$ATLAS_WARDEN_DELAY" ]] || { echo "deploy.sh: warden delayBlocks ${got} != ATLAS_WARDEN_DELAY ${ATLAS_WARDEN_DELAY}" >&2; exit 1; }
  got="$(num "$(cast call "$atlas" "timelockBlocks()(uint64)" --rpc-url "$ATLAS_RPC_URL")")"
  [[ "$got" == "$ATLAS_TIMELOCK_BLOCKS" ]] || { echo "deploy.sh: directory timelockBlocks ${got} != ATLAS_TIMELOCK_BLOCKS ${ATLAS_TIMELOCK_BLOCKS}" >&2; exit 1; }
}
verify_pair

block="$(cast block-number --rpc-url "$ATLAS_RPC_URL")"
cache="$(jq -n --argjson chainId "$ATLAS_CHAIN_ID" --argjson block "$block" --arg atlas "$atlas" --arg warden "$warden" \
  '{chainId:$chainId,block:$block,atlas:$atlas,warden:$warden,services:[]}')"
# Keep an existing cache until this run has something better to write.
if [[ ! -f "$ATLAS_EXPORT" ]]; then
  write_cache
fi

norm_hex() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

same_locator() {
  [[ "$1" == "$3" && "$(norm_hex "$2")" == "$(norm_hex "$4")" ]]
}

pending_set() {
  local v
  v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$v" == "true" || "$v" == "1" ]]
}

record_service() {
  local got_kind="$1" got_data="$2" name32="$3"
  block="$(cast block-number --rpc-url "$ATLAS_RPC_URL")"
  name_text="$(cast parse-bytes32-string "$name32")"
  cache="$(jq --argjson block "$block" --arg name "$name_text" --argjson kind "$got_kind" --arg data "$got_data" \
    '.block = $block | .services += [{name:$name,kind:$kind,data:$data}]' <<<"$cache")"
  write_cache
}

read_pending() {
  cast call "$warden" "pendingService(bytes32)(bool,uint8,bytes32,uint64)" "$1" \
    --rpc-url "$ATLAS_RPC_URL" --json
}

waiting=0
for i in "${!names[@]}"; do
  block="$(cast block-number --rpc-url "$ATLAS_RPC_URL")"
  read_json="$(cast call "$atlas" "resolve(bytes32)(uint8,bytes32)" "${names[$i]}" \
    --rpc-url "$ATLAS_RPC_URL" --block "$block" --json)"
  got_kind="$(jq -r '.[0]' <<<"$read_json")"
  got_data="$(jq -r '.[1]' <<<"$read_json")"
  if same_locator "$got_kind" "$got_data" "${kinds[$i]}" "${datas[$i]}"; then
    record_service "$got_kind" "$got_data" "${names[$i]}"
    continue
  fi

  pend_json="$(read_pending "${names[$i]}")"
  pend_exists="$(jq -r '.[0]' <<<"$pend_json")"
  pend_kind="$(jq -r '.[1]' <<<"$pend_json")"
  pend_data="$(jq -r '.[2]' <<<"$pend_json")"
  pend_at="$(jq -r '.[3]' <<<"$pend_json")"
  if pending_set "$pend_exists"; then
    if ! same_locator "$pend_kind" "$pend_data" "${kinds[$i]}" "${datas[$i]}"; then
      echo "deploy.sh: pending locator for ${names[$i]} does not match the manifest. Cancel it before scheduling." >&2
      exit 1
    fi
    if [[ "$block" -lt "$pend_at" ]]; then
      echo "deploy.sh: ${names[$i]} is scheduled until block ${pend_at}. Re-run with ATLAS_ADDRESS=${atlas}." >&2
      waiting=1
      continue
    fi
    cast send "$warden" "executeService(bytes32)" "${names[$i]}" \
      --rpc-url "$ATLAS_RPC_URL" "${scheduler_auth[@]}" >/dev/null
  else
    cast send "$warden" "scheduleService(bytes32,uint8,bytes32)" "${names[$i]}" "${kinds[$i]}" "${datas[$i]}" \
      --rpc-url "$ATLAS_RPC_URL" "${scheduler_auth[@]}" >/dev/null
    if [[ "$ATLAS_WARDEN_DELAY" -gt 0 ]]; then
      block="$(cast block-number --rpc-url "$ATLAS_RPC_URL")"
      pend_json="$(read_pending "${names[$i]}")"
      pend_exists="$(jq -r '.[0]' <<<"$pend_json")"
      pend_at="$(jq -r '.[3]' <<<"$pend_json")"
      if pending_set "$pend_exists" && [[ "$block" -lt "$pend_at" ]]; then
        echo "deploy.sh: ${names[$i]} is scheduled until block ${pend_at}. Re-run with ATLAS_ADDRESS=${atlas}." >&2
        waiting=1
        continue
      fi
      if pending_set "$pend_exists"; then
        cast send "$warden" "executeService(bytes32)" "${names[$i]}" \
          --rpc-url "$ATLAS_RPC_URL" "${scheduler_auth[@]}" >/dev/null
      fi
    fi
  fi

  block="$(cast block-number --rpc-url "$ATLAS_RPC_URL")"
  read_json="$(cast call "$atlas" "resolve(bytes32)(uint8,bytes32)" "${names[$i]}" \
    --rpc-url "$ATLAS_RPC_URL" --block "$block" --json)"
  got_kind="$(jq -r '.[0]' <<<"$read_json")"
  got_data="$(jq -r '.[1]' <<<"$read_json")"
  if ! same_locator "$got_kind" "$got_data" "${kinds[$i]}" "${datas[$i]}"; then
    echo "deploy.sh: resolve readback mismatch for index ${i}. Cache already names ${atlas}. Re-run with ATLAS_ADDRESS=${atlas}." >&2
    exit 1
  fi
  record_service "$got_kind" "$got_data" "${names[$i]}"
done

if [[ "$waiting" -eq 1 ]]; then
  echo "deploy.sh: one or more rows are scheduled and not in the cache. Re-run with ATLAS_ADDRESS=${atlas} after the warden delay." >&2
  exit 1
fi
