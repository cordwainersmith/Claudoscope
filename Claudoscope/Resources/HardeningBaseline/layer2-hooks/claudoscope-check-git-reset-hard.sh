#!/usr/bin/env python3
"""
Claudoscope Hardening Baseline - git reset --hard Guard (PreToolUse: Bash)

Blocks 'git reset --hard' unless the user's most recent message contained the
literal phrase 'git reset --hard <ref>' with a specific ref. Vague intent like
"clean up", "undo my changes", or "reset the branch" is not sufficient: a hard
reset destroys uncommitted work, and the agent must not infer the ref.

Exit 2 = deterministic block per Claude Code hook contract.
"""

import json
import os
import re
import sys

PATTERN = re.compile(r"\bgit\s+reset\s+--hard\b", re.IGNORECASE)
# Require the user's prompt to name a specific ref after `--hard`.
# Ref tokens: branch names, SHAs, HEAD~N, ORIG_HEAD, tags, etc.
# Valid examples: "git reset --hard HEAD~3", "git reset --hard origin/main",
#                 "git reset --hard a1b2c3d", "git reset --hard v1.2.0".
EXPLICIT_PATTERN = re.compile(
    r"\bgit\s+reset\s+--hard\s+([A-Za-z0-9_./~^@!:-]+)",
    re.IGNORECASE,
)


def block(reason: str) -> None:
    print(f"BLOCKED: {reason}", file=sys.stderr)
    sys.exit(2)


def get_last_user_message(transcript_path: str) -> str | None:
    """Tail-read the JSONL transcript and return the most recent user turn."""
    try:
        with open(transcript_path, "rb") as handle:
            handle.seek(0, 2)
            size = handle.tell()
            handle.seek(max(0, size - 32768))
            tail = handle.read().decode("utf-8", errors="replace")
    except Exception:
        return None

    for line in reversed(tail.splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        role = entry.get("role") or entry.get("type", "")
        if role not in ("user", "human"):
            continue
        content = entry.get("content", "")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            return " ".join(
                part.get("text", "") if isinstance(part, dict) else str(part)
                for part in content
                if not isinstance(part, dict) or part.get("type") == "text"
            )
    return None


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    command = data.get("tool_input", {}).get("command", "")
    if not PATTERN.search(command):
        sys.exit(0)

    transcript_path = data.get("transcript_path", "")
    if not transcript_path or not os.path.isfile(transcript_path):
        block(
            "'git reset --hard' requires explicit user confirmation. "
            "Type 'git reset --hard <ref>' verbatim with a specific ref "
            "(branch, SHA, HEAD~N, etc.) in your message and try again."
        )

    last_message = get_last_user_message(transcript_path)
    if not last_message:
        block(
            "'git reset --hard' requires explicit user confirmation, but no "
            "recent user message was found in the transcript. Restate the "
            "command with a specific ref."
        )

    explicit_match = EXPLICIT_PATTERN.search(last_message)
    if not explicit_match:
        block(
            "'git reset --hard' was not explicitly requested. Vague phrases "
            "like 'clean up' or 'undo my changes' are not sufficient. Restate "
            "as 'git reset --hard <ref>' (e.g. 'git reset --hard HEAD~1' or "
            "'git reset --hard origin/master') so the target is unambiguous."
        )

    sys.exit(0)


if __name__ == "__main__":
    main()
