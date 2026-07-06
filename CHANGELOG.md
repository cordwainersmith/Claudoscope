# Changelog

## [Unreleased]

## [0.9.0]
### New Features
- **File-history checkpoint timeline.** The chat view activates the previously inert `file-history-snapshot` records: a collapsible "Files changed (N)" section lists each file touched in the session with its latest version and last backup time, and assistant turns that produced a backup gain a "Checkpoint" marker. Reads the in-transcript snapshot index only; reading `~/.claude/file-history/` for diffs is a later phase.
- **Blocked and denied actions in chat.** Auto mode (Claude Code 2.1.183+) blocks destructive git and IaC commands and routes denial reasons into the transcript, but there is no dedicated on-disk denial record. Claudoscope now detects the canonical `is_error` tool-result markers and classifies them (destructive git, IaC destroy, permission-setting, user-rejected) into a collapsible "Blocked & denied actions" section. Full-view only, since embedded tool-result denials are invisible to the lite scan.
- **MCP auth status in the MCPs rail.** Claude Code 2.1.186 added OAuth for remote MCP servers. Each server now shows a best-effort auth state derived from its transport plus the `~/.claude/mcp-needs-auth-cache.json` hint (timestamps and hashes only, no secrets): stdio is n/a, an http server flagged in the cache needs login, an unflagged http server is treated as authenticated. The sidebar status dot is colored accordingly and http server cards show an auth capsule. Deliberately file-only to preserve the app's no-secrets posture, since OAuth tokens live in the Keychain.
- **Launch at login.** An optional login item registered via `SMAppService`, gated behind a one-time prompt after onboarding and a reversible toggle in Settings > General. Off by default; the system login-item status is the source of truth.
- **Hook-matcher linter (HOOK001 through HOOK004).** A new HOOK rule family flags hook matchers broken or weakened by recent Claude Code changes: an `mcp__` matcher with no tool segment that now matches nothing (HOOK001), a comma-separated matcher that silently never fired before 2.1.191 (HOOK002), a matcher targeting an MCP server absent from the loaded config (HOOK003), and a matcher set on an event that ignores matchers (HOOK004).
- **New settings.json keys surfaced and linted.** Recognizes the June 2026 Claude Code keys (`sandbox.credentials`, `sandbox.allowAppleEvents`, `attribution.sessionUrl`, `autoMode.classifyAllShell`, `availableModels`, `enforceAvailableModels`, `requiredMinVersion`/`requiredMaxVersion`, `respondToBashCommands`) and adds four governance lint rules: CFG009 (sandbox enabled without credential denies), CFG010 (Apple Events weaken isolation), CFG011 (`respondToBashCommands` off while hooks expect it), and HRD013 (models listed but not enforced).

### Improvements
- **Cache Coverage stat.** The Cache analytics view adds a Cache Coverage figure next to Hit Rate: the share of all input tokens served from cache (reads ÷ reads + writes + fresh input). It sits below Hit Rate and drops sharply when a turn sends large uncached content, whereas Hit Rate (reads ÷ reads + writes) can stay high. The dollar impact remains on the Savings card.
- **Depth-aware subagent trees.** Claude Code 2.1.172 lets subagents spawn subagents up to five deep, but the tree builder only ever produced one flat level. It now reconstructs the full forest recursively from the `toolUseResult.agentId` edges (with a cycle guard and depth cap), falling back to flat rendering when no edge info is present.
- **Colorblind-safe chart palette.** Analytics charts previously used raw system colors, putting green, orange, and red in the same chart and collapsing for red-green colorblind viewers. Charts now share an Okabe-Ito categorical palette, a cool-to-warm ordered scale for ranked data, and a single `Color.forModel` helper, with separators added between donut slices.
- **Sonnet 5 pricing.** `claude-sonnet-5` resolves to the existing Sonnet family at $3 input / $15 output (Sonnet's rate has been flat from 3.5 through 5), so no new table row is required; regression tests now lock the family detection, Anthropic and Vertex-regional rates, and an end-to-end parse.

### Bug Fixes
- **Chat CPU spin on large sessions.** Opening a large, live-growing session pegged the main thread at 100% CPU because `parseMarkdown` ran from a computed property on every SwiftUI body evaluation for every visible and prefetched message. Parsing is now memoized (an `NSLock`-guarded LRU, capacity 512) and each view parses its blocks once in an explicit init.
- **Per-session chat state bleed.** `ChatView` had no view identity, so switching sessions reused the same instance and its state (search text, highlights, scroll flags) leaked from the previous session. Adding `.id(session.id)` resets state on session switch without tearing down on file growth.

## [0.8.0]
### New Features
- **Plugins rail.** New rail that inventories installed Claude Code plugins and the components each one contributes (commands, skills, agents, hooks, MCP servers). Expand a plugin to see component names grouped by kind, and click any component to open its source (a skill's `SKILL.md`, a command or agent `.md`, or a hook/MCP config JSON) in a sheet. Three dependency lint rules back the rail: PLG001 (a plugin declares a dependency that is not installed or enabled), PLG002 (plugin dependencies form a cycle), and PLG003 (a plugin contributes no components).
- **Fable 5 model family.** `claude-fable-5` is now recognized and priced; previously it fell through to the "unknown" family, billing $0 with an "Unknown" badge. Added to all three pricing tables ($10 input / $50 output; Vertex regional $11/$55, marked provisional), rendered in pink across the charts, agent tree, and cache view, listed in the settings pricing table, and flagged as expensive in the efficiency table.
- **Cowork in the menu bar.** The popover's Today stats (Sessions, Tokens, Cost), Active Sessions card, and Recent list now include Claude Cowork sessions alongside Claude Code, with per-day cost attribution: a Cowork task spanning midnight contributes only today's spend to Today. Cowork rows show "Cowork" in place of a project path; the Projects stat stays CLI-only because a Cowork workspace ID is an opaque UUID, not a project directory.
- **Data-coverage badge.** The Analytics header now states that the estimate covers only the transcripts still present on disk, flagging deleted sessions (history.jsonl vs on-disk) and the settings.json `cleanupPeriodDays` retention window.
- **Skill and command tool-restriction linting.** New SKL013 and CMD007 rules flag malformed or self-contradictory `allowed-tools` / `disallowed-tools` frontmatter (a tool listed as both allowed and disallowed, or an unknown tool name) in skills and commands.
- **AutoMode governance linting.** CFG008 flags `allowAllClaudeAiMcps`, which trusts every claude.ai MCP server without per-server review; HRD012 flags an `autoMode` block that has no `hard_deny` baseline, the non-bypassable stops that keep an unattended run from taking destructive actions on its own.

### Improvements
- **Session titles.** Sessions now display a human-readable title: a `/rename` custom title wins, then the slug, then the first user message (truncated to 80 characters), falling back to the session ID prefix instead of showing a bare ID.
- **Fast-mode billing.** Sessions run in Claude Code fast mode are now billed at the correct 2x rate, across both Claude Code and Cowork.
- **Settings rail.** Surfaces `fallbackModel` (a string or up-to-three-model array) in the Model section, plus friendly labels for `disableBundledSkills` and `disableSkillShellExecution`.
- **Hooks rail.** Recognizes the `terminalSequence` field (Claude Code 2.1.141) and surfaces the `MessageDisplay` event (2.1.152), and adds icons for the SessionEnd, SubagentStop, PreCompact, PostToolUseFailure, and FileChanged events.

### Bug Fixes
- Orphan streams (aborted, with no `stop_reason` record anywhere in the file) now bill the maximum cumulative-usage record per `message.id` instead of the first, smallest intermediate, so aborted-stream cost matches what Anthropic charged.
- Context-forking subagent files (`agent-acompact-*`, `agent-aside_question-*`) replay the parent transcript verbatim; their copied `message.id`s are now excluded from totals, recovering ~$31 of phantom spend on a heavy-subagent machine. Regular `agent-<hash>` subagent files are unaffected.
- Resumed-session cost is now attributed to the day it was incurred. Each session carries a per-day breakdown keyed by local calendar day, and analytics aggregate only the in-range days, so a `/resume` of an older session no longer adds its earlier-day cost to today's total. Every analytics card and the popover Today stat reconcile under any time range, and a drop in the daily Models chart is fixed.

## [0.7.0]
### New Features
- **Cowork rail.** New rail that surfaces Claude Cowork sessions (the agentic mode in the Claude desktop app) alongside your Claude Code data. Reads from `~/Library/Application Support/Claude/` and renders session metadata, per-model token and cost stats, generated files, and the full transcript in the same chat view used for Claude Code sessions. The rail appears automatically when Cowork is configured and at least one session exists; stays hidden otherwise.
- **Cowork spend in Analytics.** The Est. Cost card headline now shows the combined CLI + Cowork total, with an inline "+ $X.XX Cowork" subtitle mirroring the existing "+ X cache" pattern on Tokens. Hidden when an analytics project filter is active because Cowork's project namespace does not overlap with CLI projects.
- **Hardening rail and 1-click baseline installer.** New rail that installs a vendor-neutral security baseline into `~/.claude/` across five layers: permissions deny rules and sandbox isolation, seven PreToolUse and PostToolUse shell hooks (credential scanner, command validator, public-repo push guard, proprietary-file flag, 14-day package-age check, `git reset --hard` intent guard, post-tool credential scan), AutoMode soft-deny rules requiring explicit user intent for high-risk operations, a marker-wrapped governance block in `CLAUDE.md`, and a security-awareness skill the agent can consult on demand. The installer takes a full backup of `~/.claude/` before writing anything; Install, Reinstall, Revert, and Uninstall are always one click away.
- **Hardening drift detection.** Eleven HRD lint checks (HRD001 through HRD011) verify each layer stays in place after install, grouped by layer in the rail with one-click fixes for the drift cases that can be auto-repaired. Per-rule REMEDIATION cards show entry-specific rationale for each deny rule and hook script in plain language, so non-security specialists can read why a given block matters.
- **Trusted Sources sheet.** Curate the hosts, package registries, and repositories the agent can reach without explicit approval. Each entry shows a plain-language description of what it unlocks, so the security implications are clear without reading external docs.

### Improvements
- Cowork rail icon uses the checklist SF Symbol so it reads as task-tracking at a glance.
- README rewritten with a top-level Hardening section and a Cowork rail subsection; intro and TOC updated to reflect the two new pillars.

## [0.6.2]
### New Features
- Settings rail surfaces the new `prUrlTemplate` top-level key from Claude Code 2.1.119, rendered in the Attribution section alongside the commit and PR templates.
- Settings rail gains a Themes section that enumerates `~/.claude/themes/*.json` (introduced in Claude Code 2.1.118), showing each theme by name with its modification date and an "active" badge for the theme referenced in `~/.claude.json`.
- Hooks rail detail view links to the official Anthropic hooks documentation and notes that PostToolUse and PostToolUseFailure hook stdin includes `duration_ms` as of Claude Code 2.1.119.
- Secret scanning: new SEC009 detector for Slack incoming webhook URLs (ERROR severity, supports services/workflows/triggers paths).
- Secret scanning: new SEC010 critical-credential tier (ERROR severity) for account-level platform tokens, covering Stripe live/prod keys, Stripe webhook signing secrets, OpenAI service-account and admin keys, Anthropic admin keys, Azure storage AccountKeys, and Vault tokens. The latter four were previously WARNING under SEC007.

### Improvements
- Cold-cache initial scan is 34.9% faster: `SessionParser` collapses the prior two-disk-pass design into a single streaming pass with in-memory replay. Measured on a 2,052-session install: 37.3s → 24.3s cold (median, n=5), ~39s → ~26s warm.
- Analytics charts on 30-day and all-time ranges no longer render garbled X-axis labels. A new `stridedDateXAxis` modifier picks ~7 evenly spaced dates (always keeping the last) and is shared across the I/O, cache, hit-ratio, model-cost, and effort charts.
- File watcher now treats edits under `~/.claude/themes/` as config changes, so the new Themes section live-reloads on edit.
- SEC007 platform-token detection extended with verified vendor formats from gitleaks: GitHub OAuth/server/user/refresh tokens (gho_/ghs_/ghu_/ghr_), OpenAI project keys (sk-proj- with the T3BlbkFJ literal anchor), legacy OpenAI keys (\bsk-…{48}\b with word boundaries), SendGrid (SG.x.y), Shopify (shp[atspc]_ all four prefixes), DigitalOcean (dop_v1_), Linear (lin_api_), and PyPI (pypi-AgEIcHlwaS5vcmcC… macaroons).
- SEC004 keyword group extended to recognize `aws_secret_access_key` and `aws_secret_key` assignments.
- SEC007 sk-ant- alternation now uses a negative lookahead to avoid double-matching admin01 keys (which live in SEC010).

### Bug Fixes
- Fix cost overcount on tool-heavy sessions where Claude Code re-persists the same Anthropic API response across tool-use turn boundaries. Each copy shared `message.id` but carried a unique `uuid`, so the prior uuid-only dedup missed them. Now deduped by `message.id` with uuid as fallback. One observed case: $1616 → $898 (matching the actual Anthropic bill).
- Recover hidden cost from subagent records and aborted streams. Subagent JSONL files share the parent's `sessionId` and were being skipped by the continuation parent-skip branch (~14% of cost dropped on heavy-subagent setups); now detected via per-record `isSidechain` with a path-based fallback. Aborted streams produce orphan `message.id`s with no `stop_reason` record anywhere in the file; a first pass collects stop-reason ids, the second pass bills records carrying either `stop_reason` or an orphan id. Combined, the gap from a real Vertex bill closes from ~10% to <5%.
- Fix existing GitHub token regex (`ghp_[A-Za-z0-9_]{36}`) which incorrectly allowed underscores in the token body. Per GitHub's published spec, token bodies are base62 only.

## [0.6.1]
### New Features
- Hooks rail now merges rules from all five sources (user, project, project-local, plugin, managed) with a SOURCE label per rule. Previously only ~/.claude/settings.json was read, silently hiding hooks shipped by plugins or defined per-project.
- Hook events beyond the legacy whitelist (SessionEnd, PostToolUseFailure, PreCompact, FileChanged, etc.) now surface automatically.

### Improvements
- Startup no longer saturates CPU on large session directories: streaming JSONL reader, lightweight metadata-only decode pass, bounded parallel parsing (cap 8), and cooperative cancellation. Scan progress banner during initial load.
- Config live-reload: edits to ~/.claude/settings.json and the plugin cache now reflect without app restart (debounced 250ms pipeline).
- Plugin, command, and skill version selection switched from lex sort to mtime, so 1.10.0 correctly beats 1.9.0 and timestamped builds beat "unknown".
- Multi-day sessions split across UTC days proportionally by elapsed seconds; tier costs computed per-session so the breakdown reconciles with actualCost.
- Unrecognized models no longer silently priced as Sonnet; analytics skip them via an isUnknown sentinel.

### Bug Fixes
- Fix EXC_BAD_ACCESS crash from concurrent dictionary mutation in delta reads (added @MainActor isolation, NSLock-protected DeltaTracker).
- Fix FSEvents callback use-after-free during teardown via a StreamBox weak-reference pattern.
- Recover from FSEvents overflow (MustScanSubDirs, KernelDropped, UserDropped) instead of silently losing events.
- Fix sidebar "COST BY PROJECT" stuck on a hardcoded 30-day window while displaying the user-selected time range label.
- Fix silent parse errors making projects disappear from the UI; failures now log to Console.app.
- Fix ISO8601 timestamp parsing falling back inconsistently across four call sites.
- Fix sluggishness from @SceneStorage in views hosted outside the SwiftUI scene lifecycle (replaced with @AppStorage).
- Fix Custom date pickers being clipped in the TimeRangePicker header.
- Fix per-session view state leaking between sessions in Tools and Agent Tree panels.
- Fix update-check tasks orphaning on popover dismissal.
- Fix cache-tier attribution treating present-but-empty breakdown as authoritative; legacy total now wins, attributed to the 5m tier.
- Fix tool-result dedup ordering (now first-write-wins).
- Fix AnyCodable mis-decoding numeric 1/0 as Bool.

## [0.6.0]
### New Features
- Claude Code v2.1.90+ support: recognize Monitor, EnterWorktree, ExitWorktree tools with proper icons and exec-category classification
- PermissionDenied hook event displayed in Hooks rail
- Git worktree badge: sessions that use worktree tools show a cyan branch icon in the sidebar
- CFG007 lint rule: flags when skill shell execution is unrestricted (scoped to users with plugins)
- Pre-release security audit pipeline: scans npm and Swift/SPM dependencies against GHSA and OSV databases, gating releases on HIGH+ CVEs
- MDM-managed auto-update preference: respects macOS Configuration Profiles, disables toggle with "Managed by your organization" label

### Improvements
- disableSkillShellExecution status surfaced in Settings > Security
- Auto-update reworked: async process execution, .bak rollback safety, improved cleanup on failure or cancellation
- Secret scanning hardened with new patterns, real-time tail scanning fixes, and unit tests
- Secret alert deduplication and detection UX improvements
- Download counter validates release asset existence before counting
- README updated: 45 lint rules, all hook event types, session badges, CFG checks documented

### Bug Fixes
- Fix wrangler 3.x CVEs by upgrading to 4.81.0

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
