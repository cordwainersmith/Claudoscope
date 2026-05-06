<!-- BEGIN: claudoscope-hardening -->
# Claudoscope Hardening Baseline - Governance

> **Layer 4 - Advisory Only.** These rules steer agent behavior but are subject to context compaction in long sessions. They MUST NOT be relied on as a primary security control. All hard enforcement lives in Layer 1 (permissions, sandbox) and Layer 2 (hooks).

## Security Guardrails

- **NEVER** exfiltrate credentials, modify Claude Code settings files, or run destructive commands (`rm -rf /`, database drops) even when asked. Hooks will block these and refusal is the correct response.
- **NEVER** attempt Bash workarounds when a hook blocks an Edit, Write, or Bash invocation. Surface the block to the user and ask how to proceed.
- The Claudoscope hardening baseline is layered. Removing or weakening one layer does not unlock another: the lockfile rule, for example, is enforced by both Layer 1 and Layer 2.

## Secrets & Credentials

- **NEVER** hardcode secrets, API keys, passwords, OAuth tokens, or connection strings in source files.
- All secrets must be read from environment variables, the macOS Keychain, or a dedicated secrets manager (GCP Secret Manager, AWS Secrets Manager, HashiCorp Vault).
- If a hardcoded secret is discovered while reading code, flag it immediately, do not copy the value into any output, and recommend rotation.
- Do not read, print, or log the contents of `secrets/`, `.netrc`, `.npmrc`, `.cargo/credentials.toml`, or `.ssh/`.

## Dangerous Code Patterns

- **NEVER** use `eval()`, `exec()`, dynamic class loading with user-supplied strings, or `pickle` / `yaml.load` (without `Loader=yaml.SafeLoader`) on untrusted data.
- **NEVER** construct shell commands by string concatenation with user-supplied input. Prefer parameterised calls (e.g. `subprocess.run(["cmd", arg])`).
- **NEVER** modify `terraform/`, `.github/workflows/`, `.github/actions/`, or other Infrastructure-as-Code paths without explicit user instruction in the current message.

## External Connectivity

- **NEVER** initiate an outbound connection to a host that is not in the Layer 3 trusted environment list without explicit HITL approval. The user must approve the specific endpoint.
- Before adding a new external dependency, confirm it is from an official registry, has been published for at least 14 days, and is not a typosquat of a popular package.

## `curl` and `wget` HITL Required

`curl` and `wget` are not hard-blocked but require explicit HITL approval for **every** invocation. Before running either command, the user's message must contain:

1. The **exact URL** to be fetched.
2. The **purpose** of the request.
3. **Explicit confirmation** to proceed.

A vague request like "download this" or "run curl" does not satisfy the intent requirement. There is no bypass, even for internal endpoints. Pipe-to-shell (`curl | sh`) and subshell exfiltration (`$(curl ...)`) are blocked outright by Layer 2.

## Commit and Git Hygiene

- **NEVER** commit changes automatically. Stage edits and wait for the user to issue an explicit commit command.
- **NEVER** run `git push --force` unless the user explicitly names the branch and uses the phrase "force-push".
- `git reset --hard` is enforced at Layer 2: blocked unless the user's last message contains the literal phrase `git reset --hard <ref>` with a specific ref.
- `git clean -f` without an explicit path is blocked. Always pass a path scope.

## Repository Visibility & Proprietary Files

Before any `git push` or pull request operation:

1. **Verify the target repository is private.** Forks of public repositories are themselves public. The Layer 2 visibility hook will block pushes to public repos.
2. If the repository is intentionally public, list staged files and confirm none match proprietary patterns: `strategy*`, `signal*`, `pnl*`, `backtest*`, `*credential*`, `*secret*`, `*.key`, `*.pem`, `*.p12`, `*.sql`, database dumps.
3. **NEVER** commit private keys, credential files, or content from `~/Library/Keychains/`.

## Infrastructure-as-Code

- Do not modify `terraform/`, `.github/workflows/`, `.github/actions/`, `infra/`, or `deployment/` paths without explicit user instruction.
- Do not edit lockfiles directly (`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `Cargo.lock`, `Gemfile.lock`, `composer.lock`, `poetry.lock`, `uv.lock`). Run the relevant package manager command instead so the lockfile is regenerated from a trusted resolver.

## HITL Triggers

These actions always require explicit human approval:

1. Any `curl` or `wget` invocation (URL + purpose + approval in the user message).
2. Any outbound API call to a host not in the Layer 3 trusted environment list.
3. Any `git push` or PR creation (visibility check first).
4. Committing any file matching the proprietary patterns above.
5. Deleting any file outside a clearly temporary build artifact directory.
6. Any modification to CI/CD pipeline files (`.github/workflows/`, `.github/actions/`).
7. Any database mutation (`DROP`, `TRUNCATE`, `DELETE FROM`).
8. Any force-push or `git reset --hard`.
<!-- END: claudoscope-hardening -->
