# Changelog

## [0.5.0]
### New Features
- 9 observability features: turn duration analytics (histogram + percentiles), effort level classification with donut chart and cost breakdown, subagent tree visualization in session detail, error pattern detection with sidebar badges, idle/zombie session detection, config health linter expansion (CFG001-CFG006), parallel tool call badges, SEC008 ENV_SCRUB correlation
- Timeline overhaul: time-gutter layout with project color strips, adaptive gap spacing, message type differentiation, collapsed project badges, clickable session navigation
- Config health auto-fix: one-click Apply Fix for CFG006 (subprocess env scrub)
- Rich markdown rendering in plans detail panel
- Resizable sidebar (180-400pt) with persistence and double-click reset
- Tooltips on truncated project names in sessions and analytics sidebars

### Improvements
- Wider rail buttons for better label readability
- Secret alerts fire immediately via App.init() callback, no longer require popover to be open; alert panel centered on screen

### Bug Fixes
- Fix crash in cache analytics when all sessions have zero cache tokens
- Fix UUID dedup bug (scoped per parseMetadata call) and streaming intermediate filtering

## [0.4.7]
- Tabbed analytics view with Overview, Cache, and Models segments
- Actionable cache dashboard: busting detection, stability callout, 5m/1h TTL tier breakdown, per-session efficiency table, model-aware savings
- Model analysis tab: daily cost by model chart, model efficiency table, what-if Opus-to-Sonnet calculator
- Tools rail: per-session tool call extraction, category breakdown (Read/Write/Exec/Other), tool analytics
- Command palette (Cmd+K) for quick navigation between rails
- Subagent session content loading and badge for secret scan findings
- Replaced NSPanel update dialogs with native SwiftUI Window scenes
- Improved health check scoring and popover UX

## [0.4.6]
- Added Config Health screen: 19 lint rules across CLAUDE.md, rules, and skills with group-by-rule view, severity filters, health gauge, and one-click rescan
- Added session health checks (SES001-SES004) surfacing expensive, long, or idle sessions
- Added secret detection scanning session files for leaked credentials with entropy filtering, context lines, and reveal toggle
- Added real-time secret alerts with settings toggle
- Redesigned Config Health with category navigation and human-readable rule names
- Added What's New button and full release notes in Settings > Updates
- Replaced loading skeleton with animated logo in menu bar popover
- Improved typography: bumped scale +1pt across all views
- Refactored 9 monolithic source files into ~40 focused modules

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
