#!/usr/bin/env bash
# ci-local.sh - runs the blocking CI checks locally (tasks/todo.md M1 "CI ci.yml").
#
#   1. XcodeGen drift: regenerating from project.yml must not change the committed
#      project (shasum based, so it works before the first commit too)
#   2. swift build + swift test of Packages/FXVaultKit
#   3. xcodebuild build + test of the FXVault scheme, ad-hoc signed, and a check that the
#      built app has none of the UI-testing host's code (App/UITesting)
#   4. the XCUITest suite (FXVaultUITests scheme, UITesting configuration), twice
#   5. scripts/lint.sh
#   6. scripts/check-secrets.sh
#   7. scripts/tests/release-publish-only.test.sh
#
# FXVAULT_SKIP_UI_TESTS=1 skips step 4 (macOS may ask once to allow UI automation; README).
#
# Build output goes to gitignored .build-ci-local* directories. Always ad-hoc, even
# when a Config/Local.xcconfig enables Developer ID signing, to match CI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PACKAGE_PATH="Packages/FXVaultKit"
SWIFT_SCRATCH="$PACKAGE_PATH/.build-ci-local"
DERIVED_DATA="$ROOT/.build-ci-local-dd"
# Command-line settings apply to every target, package targets included, so the
# entitlements path must be absolute (a relative one resolves inside each package).
AD_HOC_SIGNING=(
  CODE_SIGN_IDENTITY=-
  DEVELOPMENT_TEAM=
  PROVISIONING_PROFILE_SPECIFIER=
  OTHER_CODE_SIGN_FLAGS=
  "CODE_SIGN_ENTITLEMENTS=$ROOT/Config/FXVault.entitlements"
)

step() { printf '\n==> %s\n' "$*"; }

generated_hashes() {
  find FXVault.xcodeproj Config/Info.plist -type f \
    ! -path '*/xcuserdata/*' ! -name '*.xcuserstate' ! -path '*/xcshareddata/swiftpm/*' -print0 \
    | LC_ALL=C sort -z | xargs -0 shasum -a 256
}

step "XcodeGen drift check"
expected_version="$(sed -n 1p .xcodegen-version)"
installed_version="$(xcodegen --version | awk '{print $NF}')"
if [[ "$installed_version" != "$expected_version" ]]; then
  echo "XcodeGen $installed_version is installed; .xcodegen-version pins $expected_version" >&2
  exit 1
fi
before="$(generated_hashes)"
xcodegen generate --quiet
after="$(generated_hashes)"
if [[ "$before" != "$after" ]]; then
  echo "FXVault.xcodeproj was out of date with project.yml (now regenerated):" >&2
  diff <(echo "$before") <(echo "$after") >&2 || true
  exit 1
fi
echo "project is up to date"

step "swift build"
swift build --package-path "$PACKAGE_PATH" --scratch-path "$SWIFT_SCRATCH"

step "swift test"
swift test --package-path "$PACKAGE_PATH" --scratch-path "$SWIFT_SCRATCH"

step "xcodebuild build (ad-hoc)"
xcodebuild -project FXVault.xcodeproj -scheme FXVault -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" -disableAutomaticPackageResolution \
  "${AD_HOC_SIGNING[@]}" build

step "xcodebuild test (ad-hoc)"
xcodebuild -project FXVault.xcodeproj -scheme FXVault -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" -disableAutomaticPackageResolution \
  "${AD_HOC_SIGNING[@]}" test

step "xcodebuild build Release (ad-hoc)"
# Opens nothing: built only so the next step can inspect the Release binary.
xcodebuild -project FXVault.xcodeproj -scheme FXVault -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" -disableAutomaticPackageResolution \
  "${AD_HOC_SIGNING[@]}" build

step "no UI-testing code outside the UITesting build"
for config in Debug Release; do
  # Every Mach-O in Contents/MacOS: Debug builds keep the code in FXVault.debug.dylib.
  binaries="$DERIVED_DATA/Build/Products/$config/FXVault.app/Contents/MacOS"
  if [[ ! -d "$binaries" ]]; then
    echo "$config FXVault.app was not built" >&2
    exit 1
  fi
  if strings "$binaries"/* | grep -q 'fxvault-uitests'; then
    echo "$config FXVault.app contains UI-testing code (FXVAULT_UI_TESTING leaked)" >&2
    exit 1
  fi
  echo "$config: clean"
done

if [[ "${FXVAULT_SKIP_UI_TESTS:-0}" == 1 ]]; then
  step "UI tests skipped (FXVAULT_SKIP_UI_TESTS=1)"
else
  # Twice, as the e2e gate asks: a flake is a bug, never a retry.
  for run in 1 2; do
    step "UI tests (run $run of 2)"
    xcodebuild -project FXVault.xcodeproj -scheme FXVaultUITests -destination 'platform=macOS' \
      -derivedDataPath "$DERIVED_DATA" -disableAutomaticPackageResolution \
      "${AD_HOC_SIGNING[@]}" test
  done
fi

step "lint"
scripts/lint.sh

step "check-secrets"
scripts/check-secrets.sh

step "release script tests"
scripts/tests/release-publish-only.test.sh

printf '\nci-local: all checks passed\n'
