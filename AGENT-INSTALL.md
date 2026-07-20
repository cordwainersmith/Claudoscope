# Agent Install Guide: Claudoscope

This file is written for an AI coding agent (e.g. Claude Code) acting on a
user's request to install Claudoscope. A human can follow it manually too, but
the steps are ordered and gated the way an agent should execute them: gather
facts first, confirm the plan with the user, then act.

Scope: this document covers installing/updating/removing the **Claudoscope
app itself** via Homebrew. It does not cover registering the Claudoscope MCP
server or installing the Hardening baseline into `~/.claude/` — those already
have safer, reversible flows built into the app itself (see "Out of scope"
below). Do not improvise those from this file.

## Step 1 — Preflight (read-only, do not install anything yet)

Run these checks and note the results. Nothing here should write to disk.

```bash
sw_vers -productVersion   # must be 14.0 (Sonoma) or later
uname -m                  # must be arm64 (Apple Silicon); Intel is not supported
command -v brew           # Homebrew must already be installed
brew tap                  # check whether cordwainersmith/claudoscope is present
brew list --cask claudoscope   # installed version, or "No such keg" / not found
ls /Applications/Claudoscope.app 2>/dev/null   # does an app bundle already exist?
```

Interpret the results:

- If `sw_vers` is below 14.0, or `uname -m` is not `arm64`: stop. Claudoscope
  does not support this machine.
- If `brew` is not found: stop and tell the user to install Homebrew
  themselves first (https://brew.sh). Installing a package manager on the
  user's behalf is out of scope for this doc.
- If `/Applications/Claudoscope.app` exists but `brew list --cask claudoscope`
  reports it is not installed: this is a **manual-install conflict** — a
  DMG-dragged install (per the README's "Manual install" section) that
  Homebrew doesn't know about. `brew install --cask` will refuse to overwrite
  it without `--force`. Flag this to the user; do not pass `--force` silently.
- Otherwise, classify the target state as one of: fresh install, upgrade
  (older version installed), or already up to date.

## Step 2 — Approval gate

Before running anything that changes system state, present the user a short
summary of what Step 1 found and what you intend to run, for example:

| Action | Current state | Resulting state |
|---|---|---|
| Tap `cordwainersmith/claudoscope` | not tapped | tapped |
| Install cask `claudoscope` | not installed | v0.9.0 installed |

Wait for explicit confirmation before proceeding to Step 3. If Step 1 found a
manual-install conflict, the confirmation must include how the user wants to
resolve it (move the existing app aside themselves, or explicitly consent to
`--force`).

## Step 3 — Apply

```bash
brew tap cordwainersmith/claudoscope   # no-op if already tapped
```

Then, branching on the Step 1 classification:

- **Fresh install, no conflict:**
  ```bash
  brew install --cask claudoscope
  ```
- **Upgrade (older version installed):**
  ```bash
  brew upgrade --cask claudoscope
  ```
- **Already up to date:** skip, report to the user that no action was needed.
- **Manual-install conflict:** do not run `--force` unless the user explicitly
  asked for it in Step 2. Otherwise, ask them to move
  `/Applications/Claudoscope.app` aside first.

## Step 4 — Verify

```bash
brew list --cask claudoscope
ls /Applications/Claudoscope.app
```

Confirm the cask is registered and the app bundle exists, then report the
installed version back to the user. Do not auto-launch the app
(`open -a Claudoscope`) as part of install — mention it as an optional next
step the user can ask for separately.

## Uninstall (mirror of install, for symmetry)

```bash
brew uninstall --cask claudoscope
```

Ask before also running `brew untap cordwainersmith/claudoscope` — untapping
removes the ability to reinstall or update without re-adding the tap.

This does **not** remove:
- `~/Library/Application Support/Claudoscope/` (parsed-session cache,
  Hardening backups)
- Any Hardening baseline previously installed into `~/.claude/`

Those are removed via the app's own Hardening rail "Uninstall" action, not by
this doc.

## Out of scope

- **MCP server registration.** Claudoscope's Settings already has a one-click
  flow that runs `claude mcp add -s user` / `claude mcp remove -s user` on the
  user's behalf. Don't attempt to register the MCP server by editing Claude
  Code's config files directly.
- **Hardening baseline.** The Hardening rail installs a security baseline into
  `~/.claude/` with its own backup/revert/uninstall lifecycle. Don't attempt
  to replicate that from this doc.
