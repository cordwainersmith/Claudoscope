#!/usr/bin/env bash
# Claudoscope Hardening Baseline — Public Repository Visibility Check (PreToolUse: Bash)
# When the agent runs git push or gh pr create/merge against a GitHub remote,
# resolves the remote and queries gh for repo visibility. Blocks if the
# repository is public so the user can verify nothing proprietary leaks.
# Exit 2 = deterministic block.

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

# Trigger only on remote-mutating commands.
if ! printf '%s' "$COMMAND" | grep -qE '(git[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+(create|merge))'; then
  exit 0
fi

# Resolve the target remote URL. Default to origin; honour 'git push <remote>' if present.
REMOTE_NAME="origin"
if [[ "$COMMAND" =~ git[[:space:]]+push[[:space:]]+([A-Za-z0-9._-]+) ]]; then
  CANDIDATE="${BASH_REMATCH[1]}"
  case "$CANDIDATE" in
    -*) ;;  # flag, ignore
    *) REMOTE_NAME="$CANDIDATE" ;;
  esac
fi

REMOTE_URL="$(git remote get-url "$REMOTE_NAME" 2>/dev/null || echo "")"
if [[ -z "$REMOTE_URL" ]]; then
  exit 0
fi

# Extract owner/repo from HTTPS or SSH GitHub URLs (github.com only).
REPO_PATH=""
if printf '%s' "$REMOTE_URL" | grep -qE 'github\.com[:/].+/.+'; then
  REPO_PATH="$(printf '%s' "$REMOTE_URL" | sed -E 's|.*github\.com[:/]([^/]+/[^/]+)$|\1|; s|\.git$||')"
fi

if [[ -z "$REPO_PATH" ]]; then
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "WARNING: gh CLI not installed; cannot verify visibility of '$REPO_PATH' before pushing." >&2
  exit 0
fi

VISIBILITY="$(gh repo view "$REPO_PATH" --json visibility --jq '.visibility' 2>/dev/null || echo "")"

# gh returns PUBLIC, PRIVATE, or INTERNAL. Treat anything that isn't PRIVATE/INTERNAL as public.
case "$VISIBILITY" in
  PRIVATE|INTERNAL)
    exit 0
    ;;
  PUBLIC)
    {
      echo ""
      echo "BLOCKED: Target repository '$REPO_PATH' is PUBLIC."
      echo ""
      echo "  Anything pushed becomes world-readable. Forks of public repositories"
      echo "  are themselves public. Before re-running this command yourself:"
      echo "    1. Inspect staged changes with: git diff --stat HEAD"
      echo "    2. Inspect the most recent commit with: git show --stat"
      echo "    3. Confirm no credentials, internal-only data, or proprietary"
      echo "       artifacts are included."
      echo ""
      echo "  To proceed, run the push manually in your own terminal."
      echo ""
    } >&2
    exit 2
    ;;
  *)
    echo "WARNING: Could not determine visibility of '$REPO_PATH' via gh. Verify manually before pushing." >&2
    exit 0
    ;;
esac
