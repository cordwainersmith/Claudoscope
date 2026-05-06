#!/usr/bin/env python3
"""
Claudoscope Hardening Baseline - Package Age Guard (PreToolUse: Bash)

Blocks installation of any package version published less than 14 days ago
across npm/pnpm, pip/pipx, and uv. New supply-chain attacks frequently appear
as freshly-published versions; the cooling-off window gives the ecosystem time
to surface poisoned releases before they land on the developer's machine.

Network calls are bounded by a 10s per-request timeout (the hook itself is
configured with a 30s outer timeout in layer2-hooks-settings.json). If the
registry is unreachable, the hook allows the install with a warning rather
than blocking outright.
"""

import json
import re
import ssl
import sys
import urllib.request
from datetime import datetime, timedelta, timezone

MIN_AGE_DAYS = 14
HTTP_TIMEOUT = 10
USER_AGENT = "claudoscope-package-age-hook/1.0"

# Registry calls retrieve only public publication metadata, so falling back to
# an unverified TLS context is acceptable when corporate proxies break verification.
_UNVERIFIED_CTX = ssl.create_default_context()
_UNVERIFIED_CTX.check_hostname = False
_UNVERIFIED_CTX.verify_mode = ssl.CERT_NONE


def block(message: str) -> None:
    print(f"BLOCKED: {message}", file=sys.stderr)
    sys.exit(2)


def warn(message: str) -> None:
    print(f"WARNING: {message}", file=sys.stderr)


def parse_iso(value: str) -> datetime:
    cleaned = value.replace("Z", "").split("+")[0].split(".")[0]
    return datetime.fromisoformat(cleaned).replace(tzinfo=timezone.utc)


def http_get_json(url: str):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    last_error: Exception | None = None
    for context in (None, _UNVERIFIED_CTX):
        try:
            with urllib.request.urlopen(request, context=context, timeout=HTTP_TIMEOUT) as response:
                return json.loads(response.read().decode())
        except Exception as exc:
            last_error = exc
            cause = getattr(exc, "reason", exc)
            if isinstance(cause, ssl.SSLError):
                continue
            return None
    if last_error is not None:
        return None
    return None


def check_age(package_label: str, registry_label: str, version: str, published_iso: str, cutoff: datetime, now: datetime) -> None:
    published_at = parse_iso(published_iso)
    if published_at >= cutoff:
        age_days = (now - published_at).days
        block(
            f"{registry_label} package '{package_label}' version {version} "
            f"was published only {age_days} day(s) ago (on {published_iso[:10]}). "
            f"The Claudoscope hardening baseline requires packages to be at least "
            f"{MIN_AGE_DAYS} days old before installation. Pin to an older release "
            f"or wait the cooling-off period."
        )


def check_pypi(name: str, version: str | None, cutoff: datetime, now: datetime) -> None:
    normalised = name.replace("_", "-")
    url = (
        f"https://pypi.org/pypi/{normalised}/{version}/json"
        if version
        else f"https://pypi.org/pypi/{normalised}/json"
    )
    payload = http_get_json(url)
    if payload is None:
        warn(f"Could not reach PyPI for '{name}'; allowing install but verify the package age manually.")
        return

    effective_version = version
    files = []
    if version:
        files = payload.get("releases", {}).get(version, [])
    if not files:
        effective_version = payload.get("info", {}).get("version", "")
        if not effective_version:
            return
        files = payload.get("releases", {}).get(effective_version, [])
    if not files:
        return

    upload_times = [f.get("upload_time") for f in files if f.get("upload_time")]
    if not upload_times:
        return
    earliest = min(upload_times)
    check_age(name, "PyPI", effective_version, earliest, cutoff, now)


def check_npm(name: str, version: str | None, cutoff: datetime, now: datetime) -> None:
    encoded = name.replace("/", "%2F")
    payload = http_get_json(f"https://registry.npmjs.org/{encoded}")
    if payload is None:
        warn(f"Could not reach the npm registry for '{name}'; allowing install but verify the package age manually.")
        return

    times = payload.get("time", {})
    effective_version = version
    if version and version in times:
        published = times[version]
    else:
        effective_version = payload.get("dist-tags", {}).get("latest", "")
        if not effective_version:
            return
        published = times.get(effective_version, "")
    if not published:
        return

    check_age(name, "npm", effective_version, published, cutoff, now)


_PIP_VALUE_FLAGS = {
    "-i", "--index-url", "--extra-index-url", "-f", "--find-links",
    "-r", "--requirement", "-c", "--constraint", "-t", "--target",
    "--trusted-host", "--prefix", "--install-option", "--global-option",
    "-e", "--editable", "--log", "--python",
}


def extract_pip_packages(command: str):
    pattern = re.compile(r"\b(?:pip3?|pipx|uv\s+(?:add|pip\s+install))\b(.*)")
    match = pattern.search(command)
    if not match:
        return
    tokens = match.group(1).split()
    skip_next = False
    for token in tokens:
        if token in ("&&", "||", ";", "|", "&"):
            break
        if skip_next:
            skip_next = False
            continue
        if token in _PIP_VALUE_FLAGS:
            skip_next = True
            continue
        if token.startswith("-"):
            continue
        if re.match(r"(\.\.?[/\\]|/|~|git\+|hg\+|svn\+|bzr\+|https?://|file://)", token):
            continue
        if re.search(r"\.(tar\.gz|whl|zip|tar\.bz2|tgz|egg)$", token, re.IGNORECASE):
            continue
        token = re.sub(r"\[.*?\]", "", token)
        name = re.split(r"[=<>!~^@]", token)[0].strip()
        if not name or not re.match(r"^[A-Za-z0-9]", name):
            continue
        version: str | None = None
        exact = re.search(r"==([^,<>=!~^]+)", token)
        if exact:
            version = exact.group(1).strip()
        yield name, version


_NPM_SKIP_FLAGS = {
    "-g", "--global", "-D", "--save-dev", "-S", "--save", "-E", "--save-exact",
    "-O", "--save-optional", "-P", "--save-prod", "--legacy-peer-deps",
    "--no-save", "--prefer-offline", "--force", "--dry-run",
}


def extract_npm_packages(command: str):
    pattern = re.compile(r"\b(?:npm\s+(?:install|i)|pnpm\s+(?:install|add))\b(.*)")
    match = pattern.search(command)
    if not match:
        return
    tokens = match.group(1).split()
    for token in tokens:
        if token in ("&&", "||", ";", "|", "&"):
            break
        if token in _NPM_SKIP_FLAGS or token.startswith("-"):
            continue
        if re.match(r"(\.\.?[/\\]|/|https?://|git\+|github:|bitbucket:|gitlab:)", token):
            continue
        if token.startswith("@"):
            inner = token[1:]
            slash = inner.find("/")
            if slash < 0:
                continue
            scope, rest = inner[:slash], inner[slash + 1:]
            at = rest.rfind("@")
            if at > 0:
                package, raw_version = f"@{scope}/{rest[:at]}", rest[at + 1:]
            else:
                package, raw_version = f"@{scope}/{rest}", ""
        else:
            at = token.find("@")
            if at > 0:
                package, raw_version = token[:at], token[at + 1:]
            else:
                package, raw_version = token, ""
        if not package or not re.match(r"^[A-Za-z0-9@]", package):
            continue
        raw_version = re.sub(r"^[^0-9]", "", raw_version)
        version = raw_version.split("-")[0] if raw_version and raw_version[0].isdigit() else None
        yield package, version


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    command = payload.get("tool_input", {}).get("command", "")
    if not command:
        sys.exit(0)

    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=MIN_AGE_DAYS)

    if re.search(r"(^|&&|;|\|\|)\s*(pip3?|pipx|uv\s+(add|pip\s+install))\b", command):
        for name, version in extract_pip_packages(command):
            check_pypi(name, version, cutoff, now)

    if re.search(r"(^|&&|;|\|\|)\s*(npm\s+(install|i)|pnpm\s+(install|add))\b", command):
        for name, version in extract_npm_packages(command):
            check_npm(name, version, cutoff, now)


if __name__ == "__main__":
    main()
