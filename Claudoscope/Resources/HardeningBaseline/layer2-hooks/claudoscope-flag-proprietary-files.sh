#!/usr/bin/env bash
# Claudoscope Hardening Baseline — Proprietary File Flagger (PreToolUse: Bash)
# When the agent runs git add / commit / push, scans both the command line
# arguments and the current git index for filenames matching proprietary
# content patterns (strategies, signals, PnL, backtests, credentials, keys).
# Emits a warning with the matched files; exit 0 keeps the operation moving so
# the user retains control. Promote to exit 2 in stricter deployments.

set -euo pipefail

INPUT="$(cat /dev/stdin)"

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# Trigger only on staging / commit / push.
if ! printf '%s' "$COMMAND" | grep -qE 'git[[:space:]]+(add|commit|push)\b'; then
  exit 0
fi

# Patterns are case-insensitive substring/glob-like matches against basenames.
PATTERNS=(
  '^strategy.*'
  '.*[._-]strategy([._-].*)?$'
  '^signals?.*'
  '.*[._-]signals?([._-].*)?$'
  '^pnl.*'
  '.*[._-]pnl([._-].*)?$'
  '^backtest.*'
  '.*[._-]backtest([._-].*)?$'
  '.*credential.*'
  '.*secret.*'
  '.*\.key$'
  '.*\.pem$'
)

FLAGGED=()

# Scan tokens explicitly mentioned on the command line.
while IFS= read -r tok; do
  [[ -z "$tok" ]] && continue
  case "$tok" in
    -*|git|add|commit|push|origin|HEAD|master|main) continue ;;
  esac
  base="$(basename "$tok")"
  for pat in "${PATTERNS[@]}"; do
    if printf '%s' "$base" | grep -qiE "$pat"; then
      FLAGGED+=("$tok")
      break
    fi
  done
done < <(printf '%s' "$COMMAND" | tr ' \t' '\n\n')

# Scan the current git index, if available.
if git rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r staged; do
    [[ -z "$staged" ]] && continue
    base="$(basename "$staged")"
    for pat in "${PATTERNS[@]}"; do
      if printf '%s' "$base" | grep -qiE "$pat"; then
        already=false
        for f in "${FLAGGED[@]:-}"; do
          [[ "$f" == "$staged" ]] && already=true && break
        done
        $already || FLAGGED+=("$staged")
        break
      fi
    done
  done < <(git diff --cached --name-only 2>/dev/null || true)
fi

if [[ ${#FLAGGED[@]} -gt 0 ]]; then
  {
    echo ""
    echo "WARNING: Files matching proprietary content patterns were detected:"
    for f in "${FLAGGED[@]}"; do
      echo "  - $f"
    done
    echo ""
    echo "  Review each file before committing or pushing. Confirm the repository"
    echo "  is private and that no credentials, keys, or internal-only artifacts"
    echo "  are included. The Claudoscope hardening baseline does not block this"
    echo "  operation, but you must verify intent."
    echo ""
  } >&2
fi

exit 0
