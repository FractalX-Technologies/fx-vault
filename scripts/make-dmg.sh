#!/usr/bin/env bash
# make-dmg.sh - packs a macOS .app into a compressed, verified DMG (tasks/todo.md D25, M7).
#
#   scripts/make-dmg.sh <path/to/App.app> <out.dmg> <volume name>
#
# The DMG holds the app (copied with ditto, so signatures, stapled tickets and
# extended attributes survive) and an "Applications" symlink for drag-to-install.
# It is built with `diskutil image create from --format ULFO` (macOS 26+) and falls
# back to `hdiutil create -format ULFO` when diskutil lacks the image verb or fails.
# Afterwards the image is checked with `hdiutil verify` and mounted read-only to
# confirm both entries are present. The DMG is not signed here: release-local.sh
# signs, notarizes and staples it.
#
# Exit codes: 0 success, 1 failure, 2 usage error.
set -euo pipefail

readonly DMG_FORMAT="ULFO"
readonly APPLICATIONS_LINK="Applications"

die() { printf 'make-dmg: error: %s\n' "$*" >&2; exit 1; }
note() { printf 'make-dmg: %s\n' "$*"; }

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi
if [[ $# -ne 3 ]]; then
  usage >&2
  exit 2
fi

app_input="$1"
out_input="$2"
volume_name="$3"

[[ -n "$volume_name" ]] || die "the volume name is empty"
[[ "$volume_name" != */* ]] || die "the volume name must not contain '/': $volume_name"
[[ -d "$app_input" ]] || die "app bundle not found: $app_input"
[[ "$app_input" == *.app || "$app_input" == *.app/ ]] || die "not an .app bundle: $app_input"
[[ -f "$app_input/Contents/Info.plist" ]] || die "app bundle has no Contents/Info.plist: $app_input"
[[ "$out_input" == *.dmg ]] || die "output must end in .dmg: $out_input"

out_dir="$(dirname "$out_input")"
[[ -d "$out_dir" ]] || die "output directory does not exist: $out_dir"
out_dmg="$(cd "$out_dir" && pwd)/$(basename "$out_input")"
[[ ! -e "$out_dmg" ]] || die "output already exists (remove it first): $out_dmg"

app_path="$(cd "$app_input" && pwd)"
app_name="$(basename "$app_path")"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/make-dmg.XXXXXX")"
mount_point=""
cleanup() {
  if [[ -n "$mount_point" ]]; then
    hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 \
      || hdiutil detach "$mount_point" -force -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

staging="$work_dir/staging"
mkdir -p "$staging"
note "staging $app_name"
ditto "$app_path" "$staging/$app_name"
ln -s /Applications "$staging/$APPLICATIONS_LINK"

diskutil_supports_image() {
  diskutil image create from --help >/dev/null 2>&1
}

created=false
if diskutil_supports_image; then
  note "creating $DMG_FORMAT image with diskutil"
  if diskutil image create from --format "$DMG_FORMAT" --volumeName "$volume_name" \
      "$staging" "$out_dmg"; then
    created=true
  else
    note "diskutil image create failed; falling back to hdiutil"
    rm -f "$out_dmg"
  fi
else
  note "diskutil image is not available on this macOS; using hdiutil"
fi

if [[ "$created" != true ]]; then
  hdiutil create -quiet -volname "$volume_name" -srcfolder "$staging" \
    -format "$DMG_FORMAT" -ov "$out_dmg" || die "hdiutil create failed"
fi
[[ -f "$out_dmg" ]] || die "no image was written to $out_dmg"

note "verifying image checksum"
hdiutil verify -quiet "$out_dmg" || die "hdiutil verify failed for $out_dmg"

note "checking image contents"
mount_point="$work_dir/mount"
mkdir -p "$mount_point"
hdiutil attach "$out_dmg" -readonly -nobrowse -noautoopen -quiet \
  -mountpoint "$mount_point" || { mount_point=""; die "could not mount $out_dmg"; }
[[ -f "$mount_point/$app_name/Contents/Info.plist" ]] \
  || die "the image does not contain $app_name"
[[ -L "$mount_point/$APPLICATIONS_LINK" \
  && "$(readlink "$mount_point/$APPLICATIONS_LINK")" == "/Applications" ]] \
  || die "the image has no $APPLICATIONS_LINK -> /Applications link"
hdiutil detach "$mount_point" -quiet || die "could not detach $mount_point"
mount_point=""

note "wrote $out_dmg ($(du -h "$out_dmg" | awk '{print $1}'))"
