#!/usr/bin/env bash
# bump-cask.sh - renders Casks/fx-vault.rb for a release (tasks/todo.md M7, docs/RELEASING.md).
#
#   scripts/bump-cask.sh [--tap <homebrew-tap checkout>] [--check-release] <version> <dmg>
#
# Fills `version` and `sha256` of the Casks/fx-vault.rb template from <version> and the
# sha256 of <dmg> (which must be named FXVault-<version>.dmg; a FXVault-<version>.dmg.sha256
# file next to it must agree). The result goes to <tap>/Casks/fx-vault.rb, or to stdout
# without --tap. It never commits or pushes: review the diff and push the tap yourself.
#
#   --tap <path>      a checkout of FractalX-Technologies/homebrew-tap
#   --check-release   also download the published DMG from GitHub Releases and require
#                     the same sha256 (run after the release exists)
#   -h, --help        show this help
#
# Checks: `ruby -c` on the result, and `brew style` when the tap path is a tapped
# checkout under $(brew --repository)/Library/Taps (outside a tap, Homebrew's cask
# cops do not apply). Exit codes: 0 success, 1 failure, 2 usage error.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly TEMPLATE="$ROOT/Casks/fx-vault.rb"
readonly CASK_FILE="Casks/fx-vault.rb"
readonly VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$'
readonly RELEASE_URL_PREFIX="https://github.com/FractalX-Technologies/fx-vault/releases/download"
readonly DOWNLOAD_RETRIES=3

die() { printf 'bump-cask: error: %s\n' "$*" >&2; exit 1; }
note() { printf 'bump-cask: %s\n' "$*" >&2; }

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
}

tap_dir=""
check_release=false
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tap)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      tap_dir="$2"; shift ;;
    --check-release) check_release=true ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; printf '\nbump-cask: unknown option %s\n' "$1" >&2; exit 2 ;;
    *) positional+=("$1") ;;
  esac
  shift
done
[[ ${#positional[@]} -eq 2 ]] || { usage >&2; exit 2; }

version="${positional[0]#v}"
dmg="${positional[1]}"
[[ "$version" =~ $VERSION_PATTERN ]] || die "invalid version '$version'"
[[ -f "$dmg" ]] || die "DMG not found: $dmg"
[[ "$(basename "$dmg")" == "FXVault-$version.dmg" ]] \
  || die "the DMG must be named FXVault-$version.dmg (the cask URL is built from the version)"
[[ -f "$TEMPLATE" ]] || die "missing template $TEMPLATE"

sha256="$(shasum -a 256 "$dmg" | awk '{print $1}')"
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || die "could not hash $dmg"
if [[ -f "$dmg.sha256" ]]; then
  [[ "$(awk '{print $1}' "$dmg.sha256")" == "$sha256" ]] || die "$dmg.sha256 does not match the DMG"
fi

download=""
rendered="$(mktemp "${TMPDIR:-/tmp}/fx-vault-cask.XXXXXX")"
cleanup() { rm -f "$rendered" ${download:+"$download"}; }
trap cleanup EXIT

if [[ "$check_release" == true ]]; then
  url="$RELEASE_URL_PREFIX/v$version/FXVault-$version.dmg"
  download="$(mktemp "${TMPDIR:-/tmp}/fx-vault-release.XXXXXX")"
  note "downloading $url"
  curl -fsSL --retry "$DOWNLOAD_RETRIES" -o "$download" "$url" || die "could not download $url"
  [[ "$(shasum -a 256 "$download" | awk '{print $1}')" == "$sha256" ]] \
    || die "the published DMG differs from $dmg"
  note "the published DMG matches"
fi

render() {
  awk -v version="$version" -v sha="$sha256" '
    /^  version "[^"]*"$/ { print "  version \"" version "\""; versions++; next }
    /^  sha256 "[0-9a-f]{64}"$/ { print "  sha256 \"" sha "\""; shas++; next }
    { print }
    END { if (versions != 1 || shas != 1) exit 3 }
  ' "$TEMPLATE"
}

render >"$rendered" || die "the template needs exactly one 'version' and one 'sha256' line"

if command -v ruby >/dev/null 2>&1; then
  ruby -c "$rendered" >/dev/null || die "the rendered cask is not valid Ruby"
else
  note "ruby not found; syntax check skipped"
fi

if [[ -z "$tap_dir" ]]; then
  cat "$rendered"
  exit 0
fi

[[ -d "$tap_dir" ]] || die "tap checkout not found: $tap_dir"
tap_dir="$(cd "$tap_dir" && pwd)"
mkdir -p "$tap_dir/Casks"
cp "$rendered" "$tap_dir/$CASK_FILE"
note "wrote $tap_dir/$CASK_FILE (version $version, sha256 $sha256)"

if command -v brew >/dev/null 2>&1; then
  taps_root="$(brew --repository)/Library/Taps"
  if [[ "$tap_dir" == "$taps_root"/* ]]; then
    brew style "$tap_dir/$CASK_FILE" || die "brew style failed"
  else
    note "brew style skipped: $tap_dir is not under $taps_root (Homebrew's cask cops only run in a tap)"
  fi
fi

if [[ "$(git -C "$tap_dir" rev-parse --show-toplevel 2>/dev/null || true)" == "$tap_dir" ]]; then
  git -C "$tap_dir" --no-pager diff --stat -- "$CASK_FILE" >&2 || true
  note "review the diff, then: git -C '$tap_dir' add $CASK_FILE && git -C '$tap_dir' commit -m 'fx-vault $version' && git -C '$tap_dir' push"
fi
