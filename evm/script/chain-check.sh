#!/usr/bin/env bash
# Read-only. Checks the facts the EVM contracts and delays assume about a
# DuskEVM network before anything is deployed to it:
#   - the RPC chain id is the one you expect,
#   - the block time over the last ATLAS_CHECK_BLOCKS blocks (delays are
#     counted in blocks; the 5-minute and 90-day figures assume 2 seconds),
#   - which EVM opcodes the chain accepts, by simulating tiny contract
#     creations with eth_call. Nothing is sent.
# Exit 1 when the chain id differs, or the block time differs from
# ATLAS_EXPECT_BLOCK_SECONDS (default 2) by more than 10 percent. Opcode support
# is reported, not required: the contracts build for `paris`, which needs none
# of the probed opcodes. Use the report to decide whether to raise the target.
#
# Required: ATLAS_RPC_URL. Optional: ATLAS_CHAIN_ID (default 745),
# ATLAS_EXPECT_BLOCK_SECONDS, ATLAS_CHECK_BLOCKS (default 200).
# The URL must verify its TLS certificate; this script never disables that.
set -euo pipefail

: "${ATLAS_RPC_URL:?set ATLAS_RPC_URL}"
ATLAS_CHAIN_ID="${ATLAS_CHAIN_ID:-745}"
ATLAS_EXPECT_BLOCK_SECONDS="${ATLAS_EXPECT_BLOCK_SECONDS:-2}"
ATLAS_CHECK_BLOCKS="${ATLAS_CHECK_BLOCKS:-200}"

command -v python3 >/dev/null 2>&1 || { echo "chain-check: python3 is required" >&2; exit 1; }

python3 - "$ATLAS_RPC_URL" "$ATLAS_CHAIN_ID" "$ATLAS_EXPECT_BLOCK_SECONDS" "$ATLAS_CHECK_BLOCKS" <<'PY'
import json, sys, urllib.request

url, want_chain, want_secs, span = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])

def rpc(method, params=()):
    req = urllib.request.Request(
        url,
        json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)}).encode(),
        {"content-type": "application/json"},
    )
    return json.load(urllib.request.urlopen(req, timeout=20))

failed = False

chain = int(rpc("eth_chainId")["result"], 16)
print(f"chain id        {chain}  (expected {want_chain})")
if chain != want_chain:
    print("chain-check: wrong chain id", file=sys.stderr)
    sys.exit(1)

try:
    print("client          " + rpc("web3_clientVersion")["result"])
except Exception:
    print("client          (not reported)")

head = int(rpc("eth_blockNumber")["result"], 16)
stamp = lambda n: int(rpc("eth_getBlockByNumber", [hex(n), False])["result"]["timestamp"], 16)
avg = (stamp(head) - stamp(head - span)) / span
print(f"block time      {avg:.3f} s over the last {span} blocks (expected {want_secs} s)")
if abs(avg - want_secs) > want_secs * 0.10:
    print("chain-check: block time is off by more than 10 percent; delays and caps are counted in blocks", file=sys.stderr)
    failed = True

def accepts(initcode):
    # eth_call without `to` simulates a contract creation.
    out = rpc("eth_call", [{"from": "0x0000000000000000000000000000000000000001", "data": "0x" + initcode}, "latest"])
    return "result" in out

# Controls first: a probe that accepts everything proves nothing.
assert accepts("00"), "control: STOP should be accepted"
assert not accepts("fe"), "control: INVALID should be rejected"
assert not accepts("0c"), "control: an unassigned opcode should be rejected"

probes = [
    ("PUSH0", "Shanghai", "5f5ff3", False),
    ("MCOPY", "Cancun", "5f5f5f5e00", False),
    ("TLOAD", "Cancun", "5f5c5000", False),
    ("TSTORE", "Cancun", "5f5f5d00", False),
    ("BLOBHASH", "Cancun", "5f4900", False),
    ("CLZ", "Osaka", "5f1e00", False),
]
for name, fork, code, required in probes:
    ok = accepts(code)
    print(f"{name:15s} {'accepted' if ok else 'not accepted'}  ({fork})")
    if required and not ok:
        failed = True

if failed:
    sys.exit(1)
print("chain-check: ok")
PY
