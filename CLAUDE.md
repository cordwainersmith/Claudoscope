# Claudoscope

## Git Remotes

Two separate remotes with diverged histories (commit hashes differ due to author rewrite):

- `origin` — `ssh://git@github.com/cordwainersmith/Claudoscope.git` (public GitHub, author: cordwainersmith)
- `jfrog` — `git@github.jfrog.info:liranb/Claudoscope.git` (JFrog enterprise, author: liranb)

Push separately: `git push` for public GitHub, `git push jfrog master` for JFrog.

Repo-local git config uses `cordwainersmith` / `kent.rage@gmail.com`. Branch is `master` (required by JFrog).

## SSH URL Gotcha

There is a global git `insteadOf` rule that rewrites `git@github.com:` to `github-jfrog` (which uses the JFrog SSH key `id_github_jfrog`). To reach public GitHub with the correct personal key (`id_ed25519`), always use `ssh://git@github.com/...` format, which bypasses the rewrite.

This applies to: origin remote, tag pushes in `release.sh`, and the homebrew tap repo remote.

## GitHub CLI (`gh`)

Two hosts are configured:
- `github.jfrog.info` — authed as `liranb` (JFrog enterprise)
- `github.com` — authed as `cordwainersmith` (personal)

The release script sets `GH_HOST=github.com` to target the public account.

## Release & Homebrew Distribution

**Release flow:** `scripts/release.sh` (interactive)
1. Builds via `scripts/build-and-notarize.sh` (sign + Apple notarization)
2. Creates a GitHub release on `cordwainersmith/Claudoscope` with the DMG
3. Auto-updates the Homebrew cask formula in `cordwainersmith/homebrew-claudoscope`

**Homebrew tap:** `cordwainersmith/homebrew-claudoscope` (public GitHub)
- Cask formula at `Casks/claudoscope.rb`
- Local tap at `/opt/homebrew/Library/Taps/cordwainersmith/homebrew-claudoscope`
- Remote set to `ssh://` to bypass the insteadOf rewrite

**User install:**
```
brew tap cordwainersmith/claudoscope
brew install --cask claudoscope
```
