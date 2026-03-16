# Changelog

## [0.4.5]
- Added "Skip This Version" option to update popup
- "Later" now clears badge and re-prompts on next check cycle
- Fixed update popup showing twice on manual "Check for Updates"
- Fixed Dock icon disappearing when dismissing update popup while main window is open
- Fixed download cancel button not working
- Fixed URLSession leak during update downloads
- Skip redundant update check on launch if checked within the last hour

## [0.4.4]
- Support tracking multiple active sessions simultaneously in the menu bar popover
- Active sessions display in a unified card with compact rows and a pulsing indicator
- Scrollable active sessions section when more than 4 sessions are running

## [0.4.3]
- Fixed release notes text not rendering in update and What's New popups
- Improved auto-update relaunch to avoid overlapping processes

## [0.4.0]
- (Yanked, fixes were incorrect)

## [0.3.9]
- Added bundled changelog for reliable "What's New" popup after updates
- Added download count badge to README
- Added changelog gate to release script
- Fixed today's sessions filter to use proper date comparison
- Fixed watcher re-parse UUID deduplication reset
- Fixed project ID derivation for subagent paths

## [0.3.8]
- Added download tracking for Homebrew installs
- Fixed Dock icon not appearing when opening Dashboard
- Fixed version not updating on auto-update
- Fixed phantom sonnet in Model Distribution chart

## [0.3.7]
- Maintenance release with internal improvements

## [0.3.6]
- Added project-scoped memory rail
- Fixed path decoding issues

## [0.3.5]
- Added "What's New" dialog after auto-updates
- Added update notification popups

## [0.3.4]
- Improved cost estimation accuracy
- Fixed streaming record deduplication
- Added subagent session scanning

## [0.3.3]
- Added automatic self-updating via GitHub Releases
- Fixed cost estimation: per-message pricing, cache write tiers, UUID dedup

## [0.3.2]
- Added MCP server loading from project-level .mcp.json
- Added onboarding popup and about overlay
- Switched to Anthropic pricing as default
- Fixed pricing table alignment

## [0.3.1]
- New app logo
- Added Homebrew cask distribution
- Added release automation

## [0.3.0]
- Added Settings view with Security, Attribution, Plugins, and Account sections
- Added rich markdown rendering for skills and commands
- Replaced MCP list with expandable card grid
