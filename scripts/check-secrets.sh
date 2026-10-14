#!/usr/bin/env bash
# check-secrets.sh - fails if a secret could reach git.
#
# Scans every file git would publish: tracked and staged files, plus untracked files
# that are not ignored (so it is useful before the first commit). It looks for:
#   - PEM private key headers
#   - GitHub tokens (classic gh[opsu]_ prefixes and fine-grained github_pat_)
#   - AWS access key IDs
#   - only if ./.env exists: exact occurrences of any .env value of 8+ characters
#
# Values are never printed. Findings show only file:line and the rule or .env KEY
# name. Keys whose values are public identifiers (for example a team ID that the
# signing config must contain) can be listed, one per line, in
# scripts/check-secrets-allowlist.txt. Exit 0 when clean, 1 on any finding.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "check-secrets: not a git repository: $ROOT" >&2
  exit 2
fi

git ls-files -z --cached --others --exclude-standard \
  | /usr/bin/python3 -I -c '
import os
import re
import sys

MIN_VALUE_LENGTH = 8
MIN_LINE_LENGTH = 16
MAX_FILE_BYTES = 16 * 1024 * 1024
ENV_FILE = ".env"
ALLOWLIST_FILE = "scripts/check-secrets-allowlist.txt"

PATTERNS = [
    ("PEM private key", re.compile(rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----")),
    ("GitHub token", re.compile(rb"\bgh[opsu]_[A-Za-z0-9]{30,}")),
    ("GitHub fine-grained token", re.compile(rb"\bgithub_pat_[A-Za-z0-9_]{22,}")),
    ("AWS access key ID", re.compile(rb"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
]


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"\x27":
        return value[1:-1]
    return value


def env_needles():
    """(key, bytes) pairs for every .env value worth searching for."""
    if not os.path.isfile(ENV_FILE):
        return []
    allowed = set()
    if os.path.isfile(ALLOWLIST_FILE):
        with open(ALLOWLIST_FILE, encoding="utf-8") as handle:
            allowed = {line.strip() for line in handle if line.strip() and not line.startswith("#")}
    with open(ENV_FILE, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().splitlines()
    needles = []
    index = 0
    while index < len(lines):
        line = lines[index].strip()
        index += 1
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, raw = line.split("=", 1)
        key = key.strip()
        raw = raw.strip()
        if raw[:1] in ("\"", "\x27") and (len(raw) == 1 or not raw.endswith(raw[0])):
            quote = raw[0]
            parts = [raw[1:]]
            while index < len(lines):
                part = lines[index]
                index += 1
                if part.rstrip().endswith(quote):
                    parts.append(part.rstrip()[:-1])
                    break
                parts.append(part)
            value = "\n".join(parts)
        else:
            value = unquote(raw)
        if key in allowed:
            continue
        candidates = [value]
        if "\n" in value:
            candidates += [part.strip() for part in value.split("\n")
                           if len(part.strip()) >= MIN_LINE_LENGTH and not part.strip().startswith("-----")]
        for candidate in candidates:
            if len(candidate) >= MIN_VALUE_LENGTH:
                needles.append((key, candidate.encode("utf-8")))
    return needles


def line_of(data, offset):
    return data.count(b"\n", 0, offset) + 1


def main():
    paths = [p for p in sys.stdin.buffer.read().split(b"\0") if p]
    needles = env_needles()
    findings = 0
    scanned = 0
    for raw_path in paths:
        path = raw_path.decode("utf-8", errors="replace")
        if path == ENV_FILE or not os.path.isfile(path) or os.path.islink(path):
            continue
        if os.path.getsize(path) > MAX_FILE_BYTES:
            print(f"{path}: skipped (larger than {MAX_FILE_BYTES} bytes)")
            findings += 1
            continue
        with open(path, "rb") as handle:
            data = handle.read()
        scanned += 1
        for name, pattern in PATTERNS:
            for match in pattern.finditer(data):
                print(f"{path}:{line_of(data, match.start())}: {name}")
                findings += 1
        for key, needle in needles:
            start = data.find(needle)
            while start != -1:
                print(f"{path}:{line_of(data, start)}: value of .env key {key}")
                findings += 1
                start = data.find(needle, start + 1)
    env_note = f", {len(needles)} .env value(s) checked" if needles else ""
    if findings:
        print(f"check-secrets: {findings} finding(s) in {scanned} file(s){env_note}")
        return 1
    print(f"check-secrets: OK ({scanned} file(s){env_note})")
    return 0


sys.exit(main())
'
