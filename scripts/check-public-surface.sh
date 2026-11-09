#!/usr/bin/env bash
# Public-surface leak gate. Exit 0 ok, 1 blocked, 2 warnings only
# (ALLOW_PRIVATE_TIER=1). Scans the tracked tree with git grep.
#
# Some patterns below are written with a one-letter character class (for
# example `V[i]gil`) so that this file does not contain the word it blocks.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT" ]]; then
  echo "check-public-surface: not inside a git work tree" >&2
  exit 1
fi
cd "$ROOT"

ALLOWLIST_FILE="${PUBLIC_SURFACE_ALLOWLIST:-.public-surface-allowlist}"
ALLOW_PRIVATE_TIER="${ALLOW_PRIVATE_TIER:-0}"
SELF_NAME="scripts/check-public-surface.sh"

fail=0
warn=0

# Word-boundary patterns below use \b. POSIX ERE (git grep -E) does not define
# \b, so those checks would be silent no-ops on common Mac/Linux builds. PCRE
# (-P) does. Fail loud if this git lacks PCRE rather than ship a dead gate.
if [[ -n "$(git ls-files | head -n1 || true)" ]] && ! git grep -qP '^' 2>/dev/null; then
  echo "check-public-surface: git grep -P (PCRE) required; \\b checks are no-ops under -E" >&2
  exit 1
fi

is_allowlisted() {
  local line="$1"
  [[ -f "$ALLOWLIST_FILE" ]] || return 1
  while IFS= read -r pat || [[ -n "$pat" ]]; do
    [[ -z "$pat" || "$pat" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" == *"$pat"* ]]; then
      return 0
    fi
  done <"$ALLOWLIST_FILE"
  return 1
}

filter_hits() {
  # stdin: git grep lines; stdout: lines that are not allowlisted
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if is_allowlisted "$line"; then
      continue
    fi
    # .gitignore names private paths precisely so that they stay untracked.
    case "$line" in
      "$SELF_NAME":* | .public-surface-allowlist:* | .gitignore:*)
        continue
        ;;
    esac
    printf '%s\n' "$line"
  done
}

check() {
  # check <severity> <label> <regex>
  # severity: hard | soft (soft becomes a warning when ALLOW_PRIVATE_TIER=1)
  local severity="$1" label="$2" regex="$3"
  local hits
  hits="$(git grep -nIP -e "$regex" -- \
    ':!target' \
    ':!.worktrees' \
    ":!${SELF_NAME}" \
    ':!.public-surface-allowlist' \
    ':!evm/lib' \
    2>/dev/null || true)"
  if [[ -z "$hits" ]]; then
    return 0
  fi
  hits="$(printf '%s\n' "$hits" | filter_hits)"
  if [[ -z "$hits" ]]; then
    return 0
  fi
  if [[ "$severity" == soft && "$ALLOW_PRIVATE_TIER" == 1 ]]; then
    echo "WARN ($label) — ALLOW_PRIVATE_TIER=1:"
    printf '%s\n' "$hits"
    warn=1
    return 0
  fi
  echo "BLOCKED: $label"
  printf '%s\n' "$hits"
  fail=1
}

# Credential-looking assignments and key material.
check hard "possible credential" '(PASSWORD|PWD|SECRET|API_KEY|PRIVATE_KEY) *= *(['\''"][^'\''".][^'\''"]{5,}|[^'\''"[:space:].$][^[:space:]]{5,})'
check hard "private key block" '-----BEGIN [A-Z ]*PRIVATE KEY-----'
check hard "mnemonic or seed assignment" '(?i)\b(mnemonic|seed[_ ]?phrase)\b *[:=] *['\''"][a-z]+( [a-z]+){11,}'

# Machine-local paths.
check hard "absolute local path" '/(Users|home)/[a-zA-Z]'

# Private planning tier, internal tooling and names that are not public.
check soft "private doc path" '(docs/super[p]owers|docs/internal|references/|rusk-experiments)'
check soft "internal tooling name" '(nocturne-agent-[k]it|nocturne-mcp-|pit[u]itary|super[p]owers|FIELD_GU[I]DE)'
check soft "personal account path" 'a[i]chbindas'
check soft "private product name" '\b(V[i]gil|C[h]it)\b'
check soft "private project name" 'sme_[p]latform'
check soft "spec section reference" '§[0-9]'
check soft "wave/track/milestone" '\b(Wave|Track|Phase) [0-9A-Z]\b'
check soft "spec number" '\b[Ss]pec [0-9]'
check soft "escaping relative link" '\]\(\.\./\.\./\.\./'
check soft "unresolved marker" '\b(TODO|FIXME|XXX|HACK)\b'

# Encrypted provider reasoning envelopes. Hard even with ALLOW_PRIVATE_TIER=1.
check hard "encrypted thinking envelope" '"(thought_signature|encrypted_content|thinking_blocks|reasoning_details)"[[:space:]]*:[[:space:]]*"[A-Za-z0-9+/=_-]{80,}"'

# Files that never belong in the tree.
path_hits="$(git ls-files | grep -E '(^|/)agent-transcripts/|(^|/)\.dsh/|(^|/)\.env($|\.)|(^|/)AGENTS\.md$|(^|/)CLAUDE\.md$|(^|/)\.claude/|(^|/)\.cursor/|\.keystore$|(^|/)keystore/' | grep -v -E '(^|/)\.env\.example$' || true)"
if [[ -n "$path_hits" ]]; then
  echo "BLOCKED: private or local file tracked"
  printf '%s\n' "$path_hits"
  fail=1
fi

if ((fail)); then
  exit 1
fi
if ((warn)); then
  echo "check-public-surface: completed with warnings (ALLOW_PRIVATE_TIER=1)" >&2
  exit 2
fi
echo "check-public-surface: ok"
exit 0
