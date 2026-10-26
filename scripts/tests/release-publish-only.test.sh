#!/usr/bin/env bash
# release-publish-only.test.sh - release-local.sh --publish-only publishes a DMG built earlier and
# refuses one it can't check, before it touches git or GitHub (the release workflow's publish job).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/release-local.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "${stray:-}"' EXIT
failures=0

# expect_failure <name> <message> <args...>: the script must exit non-zero and print <message>.
expect_failure() {
  local name="$1" message="$2"; shift 2
  local out status=0
  out="$("$SCRIPT" "$@" 2>&1)" || status=$?
  if [[ $status -eq 0 ]] || ! grep -qF -- "$message" <<<"$out"; then
    printf 'FAIL %s (exit %s)\n%s\n' "$name" "$status" "$(tail -n 3 <<<"$out")" >&2
    failures=$((failures + 1))
  else
    printf 'ok   %s\n' "$name"
  fi
}

mkdir -p "$TMP/empty" "$TMP/tampered"
expect_failure "no DMG to publish" "no FXVault-9.9.9.dmg to publish" \
  --publish-only --output-dir "$TMP/empty" 9.9.9

printf 'built\n' > "$TMP/tampered/FXVault-9.9.9.dmg"
(cd "$TMP/tampered" && shasum -a 256 FXVault-9.9.9.dmg > FXVault-9.9.9.dmg.sha256)
printf 'changed\n' > "$TMP/tampered/FXVault-9.9.9.dmg"
expect_failure "DMG that fails its sha256" "does not match FXVault-9.9.9.dmg.sha256" \
  --publish-only --output-dir "$TMP/tampered" 9.9.9

mkdir -p "$TMP/built"
printf 'built\n' > "$TMP/built/FXVault-9.9.9.dmg"
(cd "$TMP/built" && shasum -a 256 FXVault-9.9.9.dmg > FXVault-9.9.9.dmg.sha256)
stray="$ROOT/release-test-stray-$$.txt"
touch "$stray"
expect_failure "a dirty tree names its files" "release-test-stray-$$.txt" \
  --publish-only --output-dir "$TMP/built" 9.9.9
rm -f "$stray"

expect_failure "publish-only with adhoc" "--publish needs the official signed build" \
  --publish-only --adhoc 9.9.9

[[ $failures -eq 0 ]] || { printf '%s failed\n' "$failures" >&2; exit 1; }
