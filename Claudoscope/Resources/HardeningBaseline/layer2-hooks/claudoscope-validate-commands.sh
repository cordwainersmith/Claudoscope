#!/usr/bin/env bash
# Claudoscope Hardening Baseline — Command Validator (PreToolUse: Bash)
# Blocks dangerous shell patterns: rm -rf at root/home, sudo, pipe-to-shell,
# subshell exfiltration, and unscoped destructive git clean.
# Exit 2 = deterministic block per Claude Code hook contract.

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

block() {
  echo "BLOCKED: $1" >&2
  exit 2
}

# --- Catastrophic recursive deletion ---
# Catches "rm -rf /", "rm -rf ~", "rm -rf $HOME", "rm -rf /*", "rm -rf ~/" etc.
if printf '%s' "$COMMAND" | grep -qE 'rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f[[:space:]]+(/|~|\$HOME|\$\{HOME\})([[:space:]]|/|\*|$)'; then
  block "'rm -rf' targeting filesystem root or home directory detected. This is never a recoverable operation."
fi
if printf '%s' "$COMMAND" | grep -qE 'rm[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*r[[:space:]]+(/|~|\$HOME|\$\{HOME\})([[:space:]]|/|\*|$)'; then
  block "'rm -fr' targeting filesystem root or home directory detected. This is never a recoverable operation."
fi

# --- sudo (defence-in-depth; Layer 1 already denies this) ---
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]]|;|&&|\|\|)sudo([[:space:]]|$)'; then
  block "'sudo' is not allowed from the agent. Re-run the privileged step yourself in your own terminal."
fi

# --- git clean -f without an explicit path ---
# git clean -f and git clean -fd alone wipe untracked files from CWD.
# Allow forms that supply a path argument (treated as scoped).
if printf '%s' "$COMMAND" | grep -qE 'git[[:space:]]+clean[[:space:]]+-[a-zA-Z]*f'; then
  if ! printf '%s' "$COMMAND" | grep -qE 'git[[:space:]]+clean[[:space:]]+(-[a-zA-Z]+[[:space:]]+)+[^-/[:space:]][^[:space:]]*'; then
    block "'git clean -f' without an explicit path detected. Pass a path scope (e.g. 'git clean -fd build/') so the deletion is bounded."
  fi
fi

# --- Pipe-to-shell ---
# curl ... | sh, curl ... | bash, wget ... | sh, wget ... | bash
if printf '%s' "$COMMAND" | grep -qE '(curl|wget)[[:space:]][^|]*\|[[:space:]]*(bash|sh|zsh|ksh|fish)\b'; then
  block "Pipe-to-shell pattern detected ('curl|sh' or 'wget|sh'). Download the script first, inspect it, then run it explicitly."
fi

# --- Subshell exfiltration of network content ---
# Catches $(curl ...), $(wget ...), `curl ...`, `wget ...`
if printf '%s' "$COMMAND" | grep -qE '\$\([[:space:]]*(curl|wget)\b'; then
  block "Subshell exfiltration via \$(curl ...) or \$(wget ...) detected. Capture the output to a file and inspect it before using it."
fi
if printf '%s' "$COMMAND" | grep -qE '`[[:space:]]*(curl|wget)\b'; then
  block "Backtick subshell exfiltration via curl/wget detected. Capture the output to a file and inspect it before using it."
fi

exit 0
