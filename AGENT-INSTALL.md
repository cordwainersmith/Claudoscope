# Agent Install Guide: Claudoscope

Written for an AI coding agent acting on a user's request to install
Claudoscope. Gather facts, confirm the plan with the user, then act. A human
can follow it manually too.

Scope: installing/updating/removing the **Claudoscope app itself**. MCP
server registration and the Hardening baseline already have safer, reversible
flows built into the app (see "Out of scope").

## Preflight (read-only)

```bash
uname -m                        # must be arm64 — Intel Macs are not supported
command -v brew                 # is Homebrew available?
brew list --cask claudoscope    # already installed? which version?
ls /Applications/Claudoscope.app 2>/dev/null   # app bundle already present?
```

If `/Applications/Claudoscope.app` exists but `brew list --cask claudoscope`
says it isn't installed, that's a manual (DMG) install Homebrew doesn't track.
`brew install --cask` will refuse to overwrite it without `--force` — don't
pass that flag unless the user asks for it.

## Confirm with the user

State what you found (fresh install / upgrade / already up to date / manual
install present) and what you're about to run. Wait for a yes before doing
anything below.

## Install

**Homebrew available (recommended):**

```bash
brew tap cordwainersmith/claudoscope   # no-op if already tapped
brew install --cask claudoscope        # or: brew upgrade --cask claudoscope
```

**Homebrew not available:** install the DMG directly from the latest GitHub
release:

```bash
URL=$(curl -fsSL https://api.github.com/repos/cordwainersmith/Claudoscope/releases/latest \
  | grep browser_download_url | grep '\.dmg"' | cut -d '"' -f4)
curl -fL -o /tmp/Claudoscope.dmg "$URL"
hdiutil attach /tmp/Claudoscope.dmg -nobrowse -quiet
cp -R /Volumes/Claudoscope/Claudoscope.app /Applications/
hdiutil detach /Volumes/Claudoscope -quiet
rm /tmp/Claudoscope.dmg
```

## Verify

```bash
ls /Applications/Claudoscope.app
brew list --cask claudoscope 2>/dev/null   # shows version if brew-managed
```

Report the result to the user. Don't auto-launch the app as part of install.

## Uninstall

- Brew-managed: `brew uninstall --cask claudoscope` (ask before also running
  `brew untap cordwainersmith/claudoscope`).
- DMG-managed: move `/Applications/Claudoscope.app` to the Trash.

Neither removes `~/Library/Application Support/Claudoscope/` or a previously
installed Hardening baseline — those go through the app's own Hardening rail.

## Out of scope

- **MCP server registration** — use Claudoscope's Settings, which runs
  `claude mcp add -s user` / `claude mcp remove -s user` for you.
- **Hardening baseline** — use the app's Hardening rail, which has its own
  backup/revert/uninstall lifecycle.
