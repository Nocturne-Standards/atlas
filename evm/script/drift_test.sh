#!/usr/bin/env bash
# Stub cast. Checks that drift.sh fails on the things a consumer trusts:
# wrong chain, empty cache, guardian that is not the cached warden, a warden
# that points elsewhere, and pending changes. Exit 0 on a clean directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/script/drift.sh"
ATLAS=0x2222222222222222222222222222222222222222
WARDEN=0x3333333333333333333333333333333333333333
ADDR=0x4444444444444444444444444444444444444444
DATA=0x0000000000000000000000004444444444444444444444444444444444444444
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000

works=()
cleanup() {
  for w in "${works[@]:-}"; do [[ -n "$w" ]] && rm -rf "$w"; done
}
trap cleanup EXIT

fail() {
  echo "drift_test: $*" >&2
  exit 1
}

setup() {
  work="$(mktemp -d)"
  works+=("$work")
  mkdir -p "${work}/home/.foundry/bin"
  cat >"${work}/home/.foundry/bin/cast" <<'EOF'
#!/usr/bin/env bash
sig=""
for a in "$@"; do
  case "$a" in
    *'('*) sig="$a"; break ;;
  esac
done
case "$1" in
  chain-id) echo "${S_CHAIN:-745}" ;;
  code) echo 0x6000 ;;
  format-bytes32-string) python3 -c 'import sys; s=sys.argv[1].encode(); print("0x"+s.hex().ljust(64,"0"))' "$2" ;;
  call)
    case "$sig" in
      guardian*) echo "${S_GUARDIAN:-0x3333333333333333333333333333333333333333}" ;;
      atlas*) echo "${S_WARDEN_ATLAS:-0x2222222222222222222222222222222222222222}" ;;
      scheduler*) echo 0x1111111111111111111111111111111111111111 ;;
      delayBlocks*|timelockBlocks*) echo 150 ;;
      pending\(*) echo "${S_DIR_PENDING:-[0, \"0x0000000000000000000000000000000000000000\", 0, 0]}" ;;
      pendingAdmin*) echo "${S_ADMIN_PENDING:-[0, \"0x0000000000000000000000000000000000000000\", 0, 0]}" ;;
      pendingService*) echo "${S_SVC_PENDING:-[false, 0, \"0x0000000000000000000000000000000000000000000000000000000000000000\", 0]}" ;;
      resolve*) echo "[1, \"0x0000000000000000000000004444444444444444444444444444444444444444\"]" ;;
      *) echo "cast stub: unknown call ${sig}" >&2; exit 1 ;;
    esac
    ;;
  *) echo "cast stub: unknown $1" >&2; exit 1 ;;
esac
EOF
  chmod +x "${work}/home/.foundry/bin/cast"
  export HOME="${work}/home"
  export ATLAS_RPC_URL=http://127.0.0.1:1
  export ATLAS_EXPORT="${work}/cache.json"
  unset DUSK_ATLAS_ID DRIFT_ALLOW_PENDING S_CHAIN S_GUARDIAN S_WARDEN_ATLAS S_DIR_PENDING S_ADMIN_PENDING S_SVC_PENDING || true
  write_cache '[{"name":"treasury","kind":1,"data":"'"$DATA"'"}]'
}

write_cache() {
  printf '%s\n' "{\"chainId\":745,\"block\":100,\"atlas\":\"${ATLAS}\",\"warden\":\"${WARDEN}\",\"services\":$1}" >"$ATLAS_EXPORT"
}

run() {
  set +e
  bash "$SCRIPT" >"${work}/stdout" 2>"${work}/stderr"
  rc=$?
  set -e
}

expect_fail() {
  run
  [[ "$rc" == 1 ]] || fail "$1: exit ${rc}: $(cat "${work}/stderr")"
  grep -q "$2" "${work}/stderr" || fail "$1: stderr lacks '$2': $(cat "${work}/stderr")"
  echo "ok $1"
}

setup
run
[[ "$rc" == 0 ]] || fail "clean directory exit ${rc}: $(cat "${work}/stderr")"
echo "ok clean directory"

setup; export S_CHAIN=1
expect_fail "wrong chain" "chain id"

setup; write_cache '[]'
expect_fail "empty cache" "no services"

setup; export S_GUARDIAN=0x9999999999999999999999999999999999999999
expect_fail "guardian is not the warden" "directory guardian"

setup; export S_WARDEN_ATLAS=0x9999999999999999999999999999999999999999
expect_fail "warden points elsewhere" "warden.atlas()"

setup; export S_DIR_PENDING='[1, "0x5555555555555555555555555555555555555555", 0, 999]'
expect_fail "pending directory change" "PENDING"

setup; export S_ADMIN_PENDING='[2, "0x5555555555555555555555555555555555555555", 0, 999]'
expect_fail "pending warden admin change" "PENDING"

setup; export S_SVC_PENDING='[true, 1, "'"$DATA"'", 999]'
expect_fail "pending repoint" "PENDING"

setup; export S_DIR_PENDING='[1, "0x5555555555555555555555555555555555555555", 0, 999]' DRIFT_ALLOW_PENDING=1
run
[[ "$rc" == 0 ]] || fail "allow pending exit ${rc}: $(cat "${work}/stderr")"
grep -q "notice" "${work}/stderr" || fail "allow pending did not print a notice"
echo "ok pending allowed"

echo "drift_test: ok"
