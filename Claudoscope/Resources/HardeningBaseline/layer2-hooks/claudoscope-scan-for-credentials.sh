#!/usr/bin/env bash
# Claudoscope Hardening Baseline - Credential Scanner (PostToolUse: Read|Bash)
# Scans Read or Bash output for credential-shaped strings and replaces matches
# with [CREDENTIAL REDACTED - do not use] before the agent receives them. A
# stderr warning records the redaction so the user can rotate the leaked
# secret. Exit 0 with a hookSpecificOutput tool_response override is the
# documented Claude Code mechanism for rewriting tool output.

set -euo pipefail

INPUT="$(cat /dev/stdin)"

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
if [[ "$TOOL_NAME" != "Read" && "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

# Extract the raw text payload regardless of whether tool_response is a
# string, a content block array, or an object with a content field.
CONTENT="$(printf '%s' "$INPUT" | jq -r '
  if (.tool_response | type) == "string" then .tool_response
  elif (.tool_response | type) == "object" then (.tool_response.content // (.tool_response | tostring))
  elif (.tool_response | type) == "array" then ([.tool_response[] | if type == "object" then (.text // tostring) else . end] | join("\n"))
  else ""
  end' 2>/dev/null || echo "")"

if [[ -z "$CONTENT" ]]; then
  exit 0
fi

# Single-pass redactor. Outputs the redacted body on stdout and a comma-
# separated list of matched pattern names on stderr.
SCAN_OUTPUT="$(REDACT_INPUT="$CONTENT" python3 <<'PY' 2>&1
import os
import re
import sys

REDACTION = "[CREDENTIAL REDACTED - do not use]"
SENTINEL = "\x1eCLAUDOSCOPE_HITS\x1e"

text = os.environ.get("REDACT_INPUT", "")

# Each entry is (label, compiled regex). Patterns target credential formats
# with low collision against ordinary code or prose.
PATTERNS = [
    ("AWS access key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("GitHub PAT", re.compile(r"ghp_[A-Za-z0-9]{30,}")),
    ("GitHub fine-grained PAT", re.compile(r"github_pat_[A-Za-z0-9_]{30,}")),
    ("GitHub OAuth token", re.compile(r"gho_[A-Za-z0-9]{30,}")),
    ("GitHub user-to-server token", re.compile(r"ghu_[A-Za-z0-9]{30,}")),
    ("GitHub server-to-server token", re.compile(r"ghs_[A-Za-z0-9]{30,}")),
    ("GitHub refresh token", re.compile(r"ghr_[A-Za-z0-9]{30,}")),
    ("Slack token", re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}")),
    ("OpenAI key", re.compile(r"sk-[A-Za-z0-9]{20,}")),
    ("Anthropic key", re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}")),
    ("Google API key", re.compile(r"AIza[0-9A-Za-z_-]{35}")),
    ("Stripe live key", re.compile(r"sk_live_[A-Za-z0-9]{20,}")),
    ("Generic JWT", re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
    (
        "Private key block",
        re.compile(
            r"-----BEGIN (RSA |EC |OPENSSH |DSA |ENCRYPTED |PGP )?PRIVATE KEY-----"
            r"[\s\S]+?-----END (RSA |EC |OPENSSH |DSA |ENCRYPTED |PGP )?PRIVATE KEY-----"
        ),
    ),
    # AWS secret access key heuristic: only flag when an obvious AWS context
    # marker appears, to keep false positives low.
    (
        "AWS secret access key",
        re.compile(
            r"(?:aws_secret_access_key|AWS_SECRET_ACCESS_KEY|secretAccessKey)\s*[:=]\s*[\"']?[A-Za-z0-9/+=]{40}[\"']?"
        ),
    ),
]

found: list[str] = []
out = text
for label, pattern in PATTERNS:
    if pattern.search(out):
        found.append(label)
        out = pattern.sub(REDACTION, out)

# Format: <redacted body><SENTINEL><comma-separated hit list>
sys.stdout.write(out)
sys.stdout.write(SENTINEL)
sys.stdout.write(",".join(found))
PY
)"

# Split body and hit list on the sentinel.
SENTINEL=$'\x1eCLAUDOSCOPE_HITS\x1e'
REDACTED="${SCAN_OUTPUT%${SENTINEL}*}"
HITS="${SCAN_OUTPUT##*${SENTINEL}}"

if [[ -z "$HITS" ]]; then
  exit 0
fi

{
  echo "WARNING: Credential pattern(s) detected in $TOOL_NAME output and redacted before the agent saw them."
  echo "  Patterns matched: $HITS"
  echo "  The original tool output contained one or more secrets. Take action:"
  echo "    1. Locate the source file or command that produced the secret."
  echo "    2. Rotate the credential with the issuing system immediately."
  echo "    3. Move the credential into a secrets manager (Keychain, GCP Secret Manager, etc.)."
} >&2

# Override what the agent sees with the redacted body.
jq -n --arg redacted "$REDACTED" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: "Tool output was scanned by claudoscope-scan-for-credentials.sh and one or more credential-shaped strings were redacted."
  },
  tool_response: $redacted
}'

exit 0
