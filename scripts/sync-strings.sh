#!/usr/bin/env bash
# sync-strings.sh - syncs App/Resources/Localizable.xcstrings with the strings the app code
# uses (tasks/todo.md §4.6).
#
#   1. Builds the FXVault scheme (Debug, ad-hoc) so the compiler emits .stringsdata files for
#      every String(localized:) key.
#   2. Runs `xcrun xcstringstool sync` with those files: new keys are added, keys no longer in
#      the code are marked stale, existing translations are kept.
#   3. Prints whether the catalog changed (shasum before and after). A second run must report
#      no change.
#
# Usage: scripts/sync-strings.sh [--check]
#   --check  exit 1 if the catalog was out of date (CI-style); the catalog is still updated.
#
# Build output goes to the gitignored .build-strings-dd directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CATALOG="App/Resources/Localizable.xcstrings"
DERIVED_DATA="$ROOT/.build-strings-dd"
CONFIGURATION="Debug"
check_only=0

for arg in "$@"; do
  case "$arg" in
    --check) check_only=1 ;;
    *)
      echo "usage: scripts/sync-strings.sh [--check]" >&2
      exit 2
      ;;
  esac
done

xcodebuild \
  -project FXVault.xcodeproj \
  -scheme FXVault \
  -configuration "$CONFIGURATION" \
  -destination platform=macOS \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY=- \
  build -quiet

objects_dir="$DERIVED_DATA/Build/Intermediates.noindex/FXVault.build/$CONFIGURATION/FXVault.build/Objects-normal"
stringsdata=()
while IFS= read -r -d '' file; do
  stringsdata+=("$file")
done < <(find "$objects_dir" -name '*.stringsdata' -print0)
if [[ ${#stringsdata[@]} -eq 0 ]]; then
  echo "sync-strings: no .stringsdata files under $objects_dir" >&2
  exit 1
fi

before="$(shasum -a 256 "$CATALOG" | awk '{print $1}')"
xcrun xcstringstool sync "$CATALOG" --stringsdata "${stringsdata[@]}"
after="$(shasum -a 256 "$CATALOG" | awk '{print $1}')"

if [[ "$before" == "$after" ]]; then
  echo "sync-strings: $CATALOG is up to date"
  exit 0
fi
echo "sync-strings: $CATALOG updated"
if [[ $check_only -eq 1 ]]; then
  exit 1
fi
