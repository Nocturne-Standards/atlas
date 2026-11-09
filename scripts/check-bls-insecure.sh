#!/usr/bin/env bash
# Exit 0 ok / 1 hard.
#
# Production code uses only sign/verify/sign_multisig/aggregate.
# *_insecure is allowed only on test paths listed in the allowlist, and the
# file must say why (a PreforkHostQuery comment, or the words "insecure BLS test").
#
# Matches call sites only (`name(`) — doc comments naming the symbols are OK.
#
# Bash 3.2+ compatible (macOS /bin/bash).
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT" ]]; then
  echo "check-bls-insecure: not inside a git work tree" >&2
  exit 1
fi
cd "$ROOT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWLIST="${BLS_INSECURE_ALLOWLIST:-$SCRIPT_DIR/bls-insecure-allowlist.txt}"
if [[ ! -f "$ALLOWLIST" ]]; then
  if [[ -n "${NOCTURNE_AGENT_KIT:-}" && -f "$NOCTURNE_AGENT_KIT/bin/bls-insecure-allowlist.txt" ]]; then
    ALLOWLIST="$NOCTURNE_AGENT_KIT/bin/bls-insecure-allowlist.txt"
  else
    echo "check-bls-insecure: allowlist missing at $ALLOWLIST" >&2
    echo "  restore scripts/bls-insecure-allowlist.txt, or set BLS_INSECURE_ALLOWLIST" >&2
    exit 1
  fi
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "check-bls-insecure: python3 required" >&2
  exit 1
fi
if ! command -v rg >/dev/null 2>&1; then
  echo "check-bls-insecure: ripgrep (rg) required" >&2
  exit 1
fi

export BLS_INSECURE_ALLOWLIST_PATH="$ALLOWLIST"
python3 - <<'PY'
import os, re, subprocess, sys

ALLOWLIST = os.environ["BLS_INSECURE_ALLOWLIST_PATH"]
CALL_RE = re.compile(
    r"\b(sign_insecure|verify_insecure|sign_multisig_insecure|aggregate_insecure)\s*\("
)
COMMENT_RE = re.compile(r"^\s*//")


def glob_to_re(pat: str) -> re.Pattern:
    out = []
    i = 0
    while i < len(pat):
        if pat.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pat.startswith("**", i):
            out.append(".*")
            i += 2
        elif pat[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pat[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pat[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


patterns = []
with open(ALLOWLIST, encoding="utf-8") as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        patterns.append(glob_to_re(line))


def path_allowed(path: str) -> bool:
    return any(p.match(path) for p in patterns)


def file_justified(path: str) -> bool:
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return False
    if "PreforkHostQuery" in text:
        return True
    is_test = (
        path.endswith("_tests.rs")
        or path.endswith("/tests.rs")
        or "/tests/" in path
    )
    return is_test and "insecure BLS test" in text


rg = subprocess.run(
    [
        "rg",
        "-n",
        "--glob",
        "*.rs",
        "--glob",
        "!.worktrees/**",
        "--glob",
        "!target/**",
        "--glob",
        "!vendor/**",
        "-e",
        r"\b(sign_insecure|verify_insecure|sign_multisig_insecure|aggregate_insecure)\s*\(",
        ".",
    ],
    capture_output=True,
    text=True,
)
# rg exits 1 when no matches
raw = rg.stdout or ""
hits = []
for line in raw.splitlines():
    if not line or ":" not in line:
        continue
    file, rest = line.split(":", 1)
    lineno, text = rest.split(":", 1)
    if COMMENT_RE.match(text):
        continue
    m = CALL_RE.search(text)
    if not m:
        continue
    file = file[2:] if file.startswith("./") else file
    hits.append((file, lineno, m.group(1)))

if not hits:
    print("ok: check-bls-insecure — no *_insecure BLS calls")
    sys.exit(0)

violations = 0
for file, lineno, sym in hits:
    if not path_allowed(file):
        print(
            f"BLOCKED: {file}:{lineno}:{sym} — path not on bls-insecure allowlist",
            file=sys.stderr,
        )
        violations = 1
        continue
    if not file_justified(file):
        print(
            f"BLOCKED: {file}:{lineno}:{sym} — allowlisted but the file does not say why this insecure helper is used",
            file=sys.stderr,
        )
        violations = 1
        continue

if violations:
    print("", file=sys.stderr)
    print(
        "check-bls-insecure: insecure BLS helper is not allowed here",
        file=sys.stderr,
    )
    print("  Production code may call sign, verify, sign_multisig, and aggregate only.", file=sys.stderr)
    print(
        "  Tests: list the path in scripts/bls-insecure-allowlist.txt and add a comment that names PreforkHostQuery, or the words insecure BLS test.",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"ok: check-bls-insecure — {len(hits)} hit(s) allowlisted + justified")
sys.exit(0)
PY
