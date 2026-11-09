#!/usr/bin/env bash
# Stub cast/forge. Checks the resume path:
# a matching resolve is not scheduled again;
# an existing pending row is not scheduled again;
# a row still waiting does not exit 0.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/script/deploy.sh"
FROM=0x1111111111111111111111111111111111111111
ATLAS=0x2222222222222222222222222222222222222222
WARDEN=0x3333333333333333333333333333333333333333
ADDR=0x4444444444444444444444444444444444444444
DATA=0x0000000000000000000000004444444444444444444444444444444444444444
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000

fail() {
  echo "deploy_resume_test: $*" >&2
  exit 1
}

setup() {
  work="$(mktemp -d)"
  mkdir -p "${work}/home/.foundry/bin" "${work}/out"
  cat >"${work}/home/.foundry/bin/cast" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CAST_LOG}"
sig=""
for a in "$@"; do
  case "$a" in
    *'('*) sig="$a"; break ;;
  esac
done
case "$1" in
  chain-id) echo 745 ;;
  block-number) echo 100 ;;
  format-bytes32-string)
    python3 -c 'import sys; s=sys.argv[1].encode(); print("0x"+s.hex().ljust(64,"0"))' "$2"
    ;;
  parse-bytes32-string)
    python3 -c 'import sys; h=sys.argv[1][2:]; b=bytes.fromhex(h); print(b.split(b"\x00",1)[0].decode())' "$2"
    ;;
  code)
    if [[ -n "${CAST_NO_CODE:-}" && "$2" == "${CAST_NO_CODE}" ]]; then echo 0x; else echo 0x6000; fi
    ;;
  call)
    case "$sig" in
      guardian*)
        if grep -q 'initGuardian' "${CAST_LOG}"; then echo "${CAST_WARDEN_AFTER:-${CAST_WARDEN}}"; else echo "${CAST_WARDEN}"; fi
        ;;
      chainId*)
        if [[ "$2" == "${FORGE_WARDEN}" || "$2" == "${ATLAS_WARDEN:-}" ]]; then
          echo "${CAST_WARDEN_CHAIN:-745}"
        else
          echo "${CAST_ATLAS_CHAIN:-745}"
        fi
        ;;
      atlas*) echo "${CAST_WARDEN_ATLAS:-${FORGE_ATLAS}}" ;;
      scheduler*) echo "${CAST_WARDEN_SCHEDULER:-${ATLAS_SCHEDULER}}" ;;
      delayBlocks*) echo "${CAST_DELAY:-${ATLAS_WARDEN_DELAY}}" ;;
      timelockBlocks*) echo "${CAST_TIMELOCK:-${ATLAS_TIMELOCK_BLOCKS}}" ;;
      deployer*) echo "${ATLAS_FROM}" ;;
      resolve*)
        if grep -q 'scheduleService' "${CAST_LOG}"; then
          echo "${CAST_RESOLVE_AFTER}"
        else
          echo "${CAST_RESOLVE_BEFORE}"
        fi
        ;;
      pendingService*)
        if grep -q 'scheduleService' "${CAST_LOG}"; then
          echo "${CAST_PENDING_AFTER}"
        else
          echo "${CAST_PENDING_BEFORE}"
        fi
        ;;
      *) echo "cast stub: unknown call ${sig}" >&2; exit 1 ;;
    esac
    ;;
  send)
    case "$sig" in
      scheduleService*)
        if [[ "${CAST_SCHEDULE_RC:-0}" != 0 ]]; then exit "${CAST_SCHEDULE_RC}"; fi
        ;;
      executeService*)
        if [[ "${CAST_EXECUTE_RC:-0}" != 0 ]]; then exit "${CAST_EXECUTE_RC}"; fi
        ;;
      initGuardian*) ;;
      *) echo "cast stub: unknown send ${sig}" >&2; exit 1 ;;
    esac
    ;;
  *) echo "cast stub: unknown $1" >&2; exit 1 ;;
esac
EOF
  cat >"${work}/home/.foundry/bin/forge" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FORGE_LOG}"
n="$(wc -l <"${FORGE_LOG}" | tr -d ' ')"
if [[ "$n" == 1 ]]; then
  echo "{\"deployedTo\":\"${FORGE_ATLAS}\"}"
else
  echo "{\"deployedTo\":\"${FORGE_WARDEN}\"}"
fi
EOF
  chmod +x "${work}/home/.foundry/bin/cast" "${work}/home/.foundry/bin/forge"
  export HOME="${work}/home"
  export CAST_LOG="${work}/cast.log"
  export FORGE_LOG="${work}/forge.log"
  export CAST_WARDEN="$WARDEN"
  export FORGE_ATLAS="$ATLAS"
  export FORGE_WARDEN="$WARDEN"
  export CAST_SCHEDULE_RC=0
  export CAST_EXECUTE_RC=0
  : >"$CAST_LOG"
  : >"$FORGE_LOG"
}

common_env() {
  export ATLAS_UNLOCKED=1
  export ATLAS_FROM="$FROM"
  export ATLAS_RPC_URL=http://127.0.0.1:1
  export ATLAS_SCHEDULER="$FROM"
  export ATLAS_CHAIN_ID=745
  export ATLAS_EXPORT="${work}/out/cache.json"
  export ATLAS_MANIFEST="${work}/manifest.json"
  unset ATLAS_ADDRESS || true
}

run_deploy() {
  set +e
  HOME="$HOME" bash "$SCRIPT" >"${work}/out/stdout" 2>"${work}/out/stderr"
  rc=$?
  set -e
}

assert_no_schedule() {
  if grep -q 'scheduleService' "$CAST_LOG"; then
    fail "$1 scheduled a row"
  fi
}

assert_scheduled_once() {
  n="$(grep -c 'scheduleService' "$CAST_LOG" || true)"
  [[ "$n" == 1 ]] || fail "$1 scheduleService count ${n}"
}

# Resume, resolve already matches. Must not send scheduleService. Exit 0.
setup
common_env
export ATLAS_ADDRESS="$ATLAS"
export ATLAS_WARDEN_DELAY=10
export ATLAS_TIMELOCK_BLOCKS=10
export CAST_RESOLVE_BEFORE="[1, \"${DATA}\"]"
export CAST_RESOLVE_AFTER="$CAST_RESOLVE_BEFORE"
export CAST_PENDING_BEFORE="[false, 0, \"${ZERO}\", 0]"
export CAST_PENDING_AFTER="$CAST_PENDING_BEFORE"
export CAST_SCHEDULE_RC=1
printf '%s\n' "{\"services\":[{\"name\":\"treasury\",\"kind\":1,\"address\":\"${ADDR}\"}]}" >"$ATLAS_MANIFEST"
run_deploy
[[ "$rc" == 0 ]] || fail "match resume exit ${rc}: $(cat "${work}/out/stderr")"
assert_no_schedule "match resume"
jq -e '.services | length == 1 and .[0].name == "treasury"' "$ATLAS_EXPORT" >/dev/null \
  || fail "match resume cache: $(cat "$ATLAS_EXPORT")"
echo "ok match resume"

# Resume, same locator already pending and too early. Must not schedule. Exit 1.
setup
common_env
export ATLAS_ADDRESS="$ATLAS"
export ATLAS_WARDEN_DELAY=10
export ATLAS_TIMELOCK_BLOCKS=10
export CAST_RESOLVE_BEFORE="[0, \"${ZERO}\"]"
export CAST_RESOLVE_AFTER="$CAST_RESOLVE_BEFORE"
export CAST_PENDING_BEFORE="[true, 1, \"${DATA}\", 1000]"
export CAST_PENDING_AFTER="$CAST_PENDING_BEFORE"
export CAST_SCHEDULE_RC=1
printf '%s\n' "{\"services\":[{\"name\":\"treasury\",\"kind\":1,\"address\":\"${ADDR}\"}]}" >"$ATLAS_MANIFEST"
run_deploy
[[ "$rc" == 1 ]] || fail "pending resume exit ${rc}"
assert_no_schedule "pending resume"
jq -e '.services | length == 0' "$ATLAS_EXPORT" >/dev/null \
  || fail "pending resume cache listed a row that has not landed"
echo "ok pending resume"

# First deploy, delay not elapsed. schedule once, do not exit 0.
setup
common_env
export ATLAS_WARDEN_DELAY=10
export ATLAS_TIMELOCK_BLOCKS=10
export CAST_RESOLVE_BEFORE="[0, \"${ZERO}\"]"
export CAST_RESOLVE_AFTER="$CAST_RESOLVE_BEFORE"
export CAST_PENDING_BEFORE="[false, 0, \"${ZERO}\", 0]"
export CAST_PENDING_AFTER="[true, 1, \"${DATA}\", 1000]"
export CAST_EXECUTE_RC=1
printf '%s\n' "{\"services\":[{\"name\":\"treasury\",\"kind\":1,\"address\":\"${ADDR}\"}]}" >"$ATLAS_MANIFEST"
run_deploy
[[ "$rc" == 1 ]] || fail "fresh delay exit ${rc}"
assert_scheduled_once "fresh delay"
if grep -q 'executeService' "$CAST_LOG"; then
  fail "fresh delay sent executeService before the delay"
fi
jq -e '.services | length == 0' "$ATLAS_EXPORT" >/dev/null \
  || fail "fresh delay cache listed a row that has not landed"
echo "ok fresh delay"

# Delay 0 executes inside scheduleService. One schedule, cache records the row.
setup
common_env
export ATLAS_WARDEN_DELAY=0
export ATLAS_TIMELOCK_BLOCKS=1
export CAST_RESOLVE_BEFORE="[0, \"${ZERO}\"]"
export CAST_RESOLVE_AFTER="[1, \"${DATA}\"]"
export CAST_PENDING_BEFORE="[false, 0, \"${ZERO}\", 0]"
export CAST_PENDING_AFTER="$CAST_PENDING_BEFORE"
printf '%s\n' "{\"services\":[{\"name\":\"treasury\",\"kind\":1,\"address\":\"${ADDR}\"}]}" >"$ATLAS_MANIFEST"
run_deploy
[[ "$rc" == 0 ]] || fail "delay 0 exit ${rc}: $(cat "${work}/out/stderr")"
assert_scheduled_once "delay 0"
if grep -q 'executeService' "$CAST_LOG"; then
  fail "delay 0 sent a second executeService"
fi
jq -e '.services | length == 1' "$ATLAS_EXPORT" >/dev/null || fail "delay 0 cache"
echo "ok delay 0"

manifest_one() {
  printf '%s\n' "{\"services\":[{\"name\":\"$1\",\"kind\":1,\"address\":\"${ADDR}\"}]}" >"$ATLAS_MANIFEST"
}

# A wrong ATLAS_WARDEN on resume: no code, another directory, another chain,
# another scheduler or delay. initGuardian is final, so nothing is sent.
for mismatch in CAST_NO_CODE="$WARDEN" CAST_WARDEN_ATLAS=0x9999999999999999999999999999999999999999 \
  CAST_WARDEN_CHAIN=1 CAST_WARDEN_SCHEDULER=0x5555555555555555555555555555555555555555 CAST_DELAY=3; do
  setup
  common_env
  export ATLAS_ADDRESS="$ATLAS"
  export ATLAS_WARDEN="$WARDEN"
  export ATLAS_WARDEN_DELAY=10
  export ATLAS_TIMELOCK_BLOCKS=10
  export CAST_WARDEN=0x0000000000000000000000000000000000000000
  export CAST_WARDEN_AFTER="$WARDEN"
  export CAST_RESOLVE_BEFORE="[0, \"${ZERO}\"]"
  export CAST_RESOLVE_AFTER="$CAST_RESOLVE_BEFORE"
  export CAST_PENDING_BEFORE="[false, 0, \"${ZERO}\", 0]"
  export CAST_PENDING_AFTER="$CAST_PENDING_BEFORE"
  export "$mismatch"
  manifest_one treasury
  run_deploy
  [[ "$rc" == 1 ]] || fail "warden ${mismatch} exit ${rc}"
  grep -q 'initGuardian not sent' "${work}/out/stderr" || fail "warden ${mismatch}: $(cat "${work}/out/stderr")"
  if grep -q 'initGuardian' "$CAST_LOG"; then fail "warden ${mismatch} sent initGuardian"; fi
  assert_no_schedule "warden ${mismatch}"
  [[ ! -f "$ATLAS_EXPORT" ]] || fail "warden ${mismatch} wrote a cache"
  unset CAST_NO_CODE CAST_WARDEN_ATLAS CAST_WARDEN_CHAIN CAST_WARDEN_SCHEDULER CAST_DELAY ATLAS_WARDEN
done
echo "ok wrong ATLAS_WARDEN refused before initGuardian"

# Resume where initGuardian never landed, no ATLAS_WARDEN: refuse, send nothing, keep the cache.
setup
common_env
export ATLAS_ADDRESS="$ATLAS"
export ATLAS_WARDEN_DELAY=10
export ATLAS_TIMELOCK_BLOCKS=10
export CAST_WARDEN=0x0000000000000000000000000000000000000000
export CAST_RESOLVE_BEFORE="[0, \"${ZERO}\"]"
export CAST_RESOLVE_AFTER="$CAST_RESOLVE_BEFORE"
export CAST_PENDING_BEFORE="[false, 0, \"${ZERO}\", 0]"
export CAST_PENDING_AFTER="$CAST_PENDING_BEFORE"
manifest_one treasury
printf '%s\n' '{"sentinel":true}' >"$ATLAS_EXPORT"
run_deploy
[[ "$rc" == 1 ]] || fail "zero guardian resume exit ${rc}"
grep -q 'ATLAS_WARDEN' "${work}/out/stderr" || fail "zero guardian resume did not name ATLAS_WARDEN"
assert_no_schedule "zero guardian resume"
if grep -q 'initGuardian' "$CAST_LOG"; then fail "zero guardian resume sent initGuardian without ATLAS_WARDEN"; fi
jq -e '.sentinel == true' "$ATLAS_EXPORT" >/dev/null || fail "zero guardian resume overwrote the cache"
echo "ok zero guardian refuses"

# Same, with ATLAS_WARDEN and the deployer signing: initGuardian is sent, then the run completes.
setup
common_env
export ATLAS_ADDRESS="$ATLAS"
export ATLAS_WARDEN="$WARDEN"
export ATLAS_WARDEN_DELAY=0
export ATLAS_TIMELOCK_BLOCKS=1
export CAST_WARDEN=0x0000000000000000000000000000000000000000
export CAST_WARDEN_AFTER="$WARDEN"
export CAST_RESOLVE_BEFORE="[0, \"${ZERO}\"]"
export CAST_RESOLVE_AFTER="[1, \"${DATA}\"]"
export CAST_PENDING_BEFORE="[false, 0, \"${ZERO}\", 0]"
export CAST_PENDING_AFTER="$CAST_PENDING_BEFORE"
manifest_one treasury
run_deploy
[[ "$rc" == 0 ]] || fail "finish initGuardian exit ${rc}: $(cat "${work}/out/stderr")"
grep -q 'initGuardian' "$CAST_LOG" || fail "initGuardian was not sent"
jq -e --arg w "$WARDEN" '.warden == $w and (.services | length == 1)' "$ATLAS_EXPORT" >/dev/null \
  || fail "finish initGuardian cache: $(cat "$ATLAS_EXPORT")"
unset ATLAS_WARDEN
echo "ok finish initGuardian"

# A directory on another chain, or paired with another scheduler, delay or timelock, is not cached or scheduled.
for mismatch in CAST_ATLAS_CHAIN=1 CAST_DELAY=3 CAST_TIMELOCK=3 CAST_WARDEN_ATLAS=0x9999999999999999999999999999999999999999; do
  setup
  common_env
  export ATLAS_ADDRESS="$ATLAS"
  export ATLAS_WARDEN_DELAY=10
  export ATLAS_TIMELOCK_BLOCKS=10
  export CAST_RESOLVE_BEFORE="[0, \"${ZERO}\"]"
  export CAST_RESOLVE_AFTER="$CAST_RESOLVE_BEFORE"
  export CAST_PENDING_BEFORE="[false, 0, \"${ZERO}\", 0]"
  export CAST_PENDING_AFTER="$CAST_PENDING_BEFORE"
  export "$mismatch"
  manifest_one treasury
  run_deploy
  [[ "$rc" == 1 ]] || fail "${mismatch} exit ${rc}"
  assert_no_schedule "$mismatch"
  [[ ! -f "$ATLAS_EXPORT" ]] || fail "${mismatch} wrote a cache"
  unset CAST_ATLAS_CHAIN CAST_DELAY CAST_TIMELOCK CAST_WARDEN_ATLAS
done
echo "ok pairing mismatches refused"

# Bad and duplicate names are refused before anything is deployed.
for bad in "-abc" "--help" "a b" "$(printf 'x%.0s' $(seq 1 33))"; do
  setup
  common_env
  export ATLAS_WARDEN_DELAY=10
  export ATLAS_TIMELOCK_BLOCKS=10
  manifest_one "$bad"
  run_deploy
  [[ "$rc" == 1 ]] || fail "name '${bad}' exit ${rc}"
  [[ ! -s "$FORGE_LOG" ]] || fail "name '${bad}' deployed contracts"
done
setup
common_env
export ATLAS_WARDEN_DELAY=10
export ATLAS_TIMELOCK_BLOCKS=10
printf '%s\n' "{\"services\":[{\"name\":\"treasury\",\"kind\":1,\"address\":\"${ADDR}\"},{\"name\":\"treasury\",\"kind\":1,\"address\":\"${ADDR}\"}]}" >"$ATLAS_MANIFEST"
run_deploy
[[ "$rc" == 1 ]] || fail "duplicate names exit ${rc}"
[[ ! -s "$FORGE_LOG" ]] || fail "duplicate names deployed contracts"
echo "ok names"

# README must describe the non-zero wait and the skip.
readme="${ROOT}/README.md"
grep -q 'exits 1' "$readme" || fail "README does not say a waiting row exits 1"
grep -q 'not scheduled again' "$readme" || fail "README does not say a matching row is not scheduled again"
echo "ok readme"

echo "deploy_resume_test: ok"
