#!/usr/bin/env bash
# Claudoscope Hardening Baseline — File Protector (PreToolUse: Write|Edit|MultiEdit)
# Blocks modification of package lockfiles and Claude Code settings files.
# Emits a structured decision JSON to stdout and exits 0 (Claude Code hook contract).

set -euo pipefail

INPUT="$(cat /dev/stdin)"

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty')"

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

emit_block() {
  local reason="$1"
  jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
  exit 0
}

BASENAME="$(basename "$FILE_PATH")"

# --- Lockfiles (always blocked) ---
case "$BASENAME" in
  package-lock.json|yarn.lock|pnpm-lock.yaml|Cargo.lock|Gemfile.lock|composer.lock|poetry.lock|uv.lock)
    emit_block "Direct modification of lockfile '$BASENAME' is not permitted. Run the matching package manager command (npm install, cargo update, uv lock, etc.) so the lockfile is regenerated from a trusted resolver."
    ;;
esac

# --- requirements.txt only when it carries pip-compile / uv-style hash pins ---
if [[ "$BASENAME" == "requirements.txt" ]]; then
  if [[ -f "$FILE_PATH" ]] && grep -qE '(--hash=|# via )' "$FILE_PATH" 2>/dev/null; then
    emit_block "'requirements.txt' at '$FILE_PATH' looks like a generated lockfile (contains --hash= or '# via' markers). Regenerate it with pip-compile / uv pip compile rather than editing in place."
  fi
fi

# --- Claude Code settings files ---
case "$FILE_PATH" in
  *"/.claude/settings.json"|*"/.claude/settings.local.json")
    emit_block "Modification of Claude Code settings '$FILE_PATH' is not permitted by the Claudoscope hardening baseline. Use the Claudoscope Settings sheet so the change is audited and re-signed."
    ;;
esac

exit 0
