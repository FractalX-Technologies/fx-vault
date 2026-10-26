#!/usr/bin/env bash
# release-local.sh - builds the universal FX Vault DMG (tasks/todo.md D25, M7, docs/RELEASING.md).
#
#   scripts/release-local.sh [options] <version>
#
# Official mode (default): Developer ID signing and notarization, in the release workflow's
# signed job (organization secrets) or on the maintainer's Mac.
#   1. Preflight: tools, Config/Local.xcconfig (includes Signed.xcconfig), effective
#      build settings, provisioning profile, signing identity, notary keychain profile,
#      optional clean-tree check, `xcodegen generate`, optional tests (scripts/ci-local.sh).
#   2. `xcodebuild archive` (Release, arm64 + x86_64), then `-exportArchive` with
#      ci/ExportOptions-DeveloperID.plist pinned to the resolved certificate and profile.
#   3. Renames FXVault.app to "FX Vault.app" and runs the gates: codesign --verify
#      --deep --strict, universal binary, version, hardened runtime, Developer ID
#      authority and team, entitlements contain keychain-access-groups and no
#      get-task-allow, embedded profile team and UUID.
#   4. Notarizes (notarytool --keychain-profile, --wait) and staples the app, then checks
#      `spctl -t exec` and `syspolicy_check distribution`; builds the DMG with
#      scripts/make-dmg.sh, signs it, notarizes and staples it, then checks
#      `xcrun stapler validate` and `spctl -a -vvv -t install`.
#   5. Writes dist/FXVault-<version>.dmg and dist/FXVault-<version>.dmg.sha256.
#   6. With --publish only: uploads both files to the GitHub release v<version>.
#
# Publish-only mode (--publish-only): uploads a DMG and .sha256 built earlier (in --output-dir)
# without building, so the job that holds the signing keys never needs `contents: write`.
#
# Ad-hoc mode (--adhoc): for forks and the CI verification artifact. No Apple account,
# no profile, no notarization, no Touch ID. Writes dist/FXVault-<version>-adhoc.dmg.
#
# Options:
#   --adhoc                  ad-hoc signed build (see above)
#   --skip-tests             do not run scripts/ci-local.sh before building
#   --require-clean          fail if the git working tree has any change
#   --skip-notarize          official mode, but stop after signing and the DMG
#                            (local verification only; nothing is written to dist/)
#   --publish                upload to GitHub release v<version> (implies
#                            --require-clean; tag v<version> must be pushed and be HEAD)
#   --publish-only           only publish the DMG and .sha256 already in --output-dir
#                            (checks the sha256, the tag and the release like --publish)
#   --prerelease             mark a newly created GitHub release as a pre-release
#                            (automatic when the version has a -suffix)
#   --profile <x>            provisioning profile: file path, UUID or name
#                            (default: PROVISIONING_PROFILE_SPECIFIER of the app target)
#   --identity <sha1>        Developer ID Application identity (default: the newest
#                            valid identity whose certificate is in the profile)
#   --build-number <n>       CFBundleVersion (default: git commit count of HEAD)
#   --team-id <id>           expected Apple team (default: QYKC498D5D)
#   --notary-profile <name>  notarytool keychain profile (default: fxvault-notary)
#   --notary-keychain <path> keychain holding that profile (default: ~/Library/Keychains/login.keychain-db)
#   --output-dir <dir>       where the DMG and .sha256 go (default: dist)
#   --repo <owner/name>      GitHub repository for --publish
#                            (default: FractalX-Technologies/fx-vault)
#   -h, --help               show this help
#
# Build output goes to .build-release/<version> (gitignored); logs are in its logs/
# folder. Secret values are never printed: notarization reads its credentials from
# the keychain profile, and signing uses identities already in the keychain.
#
# Exit codes: 0 success, 1 failure, 2 usage error.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly PROJECT="$ROOT/FXVault.xcodeproj"
readonly SCHEME="FXVault"
readonly TARGET="FXVault"
readonly PRODUCT_NAME="FXVault"
readonly BUNDLE_ID="io.fractalx.fxvault"
readonly APP_NAME="FX Vault.app"
readonly DISPLAY_NAME="FX Vault"
readonly VOLUME_NAME="FX Vault"
readonly DMG_BASENAME="FXVault"
readonly DEFAULT_TEAM_ID="QYKC498D5D"
readonly DEFAULT_NOTARY_PROFILE="fxvault-notary"
readonly DEFAULT_REPO="FractalX-Technologies/fx-vault"
readonly NOTARY_TIMEOUT="2h"
readonly ARCHS_REQUIRED="arm64 x86_64"
readonly LOG_TAIL_LINES=60
readonly EXPORT_OPTIONS_TEMPLATE="$ROOT/ci/ExportOptions-DeveloperID.plist"
readonly LOCAL_XCCONFIG="$ROOT/Config/Local.xcconfig"
readonly SIGNED_ENTITLEMENTS="Config/FXVault-Signed.entitlements"
readonly ADHOC_ENTITLEMENTS="$ROOT/Config/FXVault.entitlements"
readonly XCODE_PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
readonly LEGACY_PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
readonly VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$'
readonly GATE_NOTARIZED_SOURCE="source=Notarized Developer ID"

# ---------------------------------------------------------------- output helpers

die() { printf '\nrelease: error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'release: warning: %s\n' "$*" >&2; }
note() { printf 'release: %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
pass() { printf '    ok  %s\n' "$*"; }

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
}

trap 'status=$?; if [[ $status -ne 0 ]]; then printf "release: failed (exit %s) at line %s: %s\n" "$status" "$LINENO" "$BASH_COMMAND" >&2; fi' ERR

# ---------------------------------------------------------------- arguments

mode="signed"
run_tests=true
require_clean=false
notarize=true
publish=false
publish_only=false
prerelease=false
profile_arg=""
identity_arg=""
build_number=""
team_id="$DEFAULT_TEAM_ID"
notary_profile="$DEFAULT_NOTARY_PROFILE"
notary_keychain="$HOME/Library/Keychains/login.keychain-db"   # explicit: notarytool may not find profiles without it
output_dir="$ROOT/dist"
repo="$DEFAULT_REPO"
version=""

need_value() { [[ $# -ge 2 && -n "$2" ]] || { usage >&2; printf '\nrelease: %s needs a value\n' "$1" >&2; exit 2; }; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --adhoc) mode="adhoc" ;;
    --skip-tests) run_tests=false ;;
    --require-clean) require_clean=true ;;
    --skip-notarize) notarize=false ;;
    --publish) publish=true; require_clean=true ;;
    --publish-only) publish_only=true; publish=true; require_clean=true ;;
    --prerelease) prerelease=true ;;
    --profile) need_value "$@"; profile_arg="$2"; shift ;;
    --identity) need_value "$@"; identity_arg="$2"; shift ;;
    --build-number) need_value "$@"; build_number="$2"; shift ;;
    --team-id) need_value "$@"; team_id="$2"; shift ;;
    --notary-profile) need_value "$@"; notary_profile="$2"; shift ;;
    --notary-keychain) need_value "$@"; notary_keychain="$2"; shift ;;
    --output-dir) need_value "$@"; output_dir="$2"; shift ;;
    --repo) need_value "$@"; repo="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) usage >&2; printf '\nrelease: unknown option %s\n' "$1" >&2; exit 2 ;;
    *)
      [[ -z "$version" ]] || { usage >&2; printf '\nrelease: more than one version given\n' >&2; exit 2; }
      version="$1"
      ;;
  esac
  shift
done
if [[ $# -gt 0 ]]; then
  [[ -z "$version" && $# -eq 1 ]] || { usage >&2; exit 2; }
  version="$1"
fi
[[ -n "$version" ]] || { usage >&2; printf '\nrelease: missing <version>\n' >&2; exit 2; }

version="${version#v}"
[[ "$version" =~ $VERSION_PATTERN ]] \
  || die "invalid version '$version': use MAJOR.MINOR.PATCH with an optional -suffix (for example 0.1.0 or 0.1.0-beta.1)"
marketing_version="${version%%-*}"
[[ "$version" == "$marketing_version" ]] || prerelease=true
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || die "invalid team ID '$team_id'"
[[ -z "$identity_arg" || "$identity_arg" =~ ^[0-9A-Fa-f]{40}$ ]] \
  || die "--identity must be the 40-character SHA-1 shown by 'security find-identity -v -p codesigning'"
[[ -z "$build_number" || "$build_number" =~ ^[1-9][0-9]*$ ]] || die "--build-number must be a positive integer"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid --repo '$repo'"

if [[ "$mode" == "adhoc" ]]; then
  [[ "$publish" == false ]] || die "--publish needs the official signed build; ad-hoc builds are never published"
  [[ -z "$profile_arg" && -z "$identity_arg" ]] || die "--profile and --identity do not apply to --adhoc"
  notarize=false
fi
if [[ "$publish" == true && "$notarize" == false ]]; then
  die "--publish cannot be combined with --skip-notarize"
fi

if [[ "$output_dir" != /* ]]; then output_dir="$PWD/$output_dir"; fi

build_suffix=""
if [[ "$mode" == "adhoc" ]]; then build_suffix="-adhoc"; fi
readonly BUILD_DIR="$ROOT/.build-release/${version}${build_suffix}"
readonly LOG_DIR="$BUILD_DIR/logs"
readonly WORK_DIR="$BUILD_DIR/work"
readonly ARCHIVE="$BUILD_DIR/$PRODUCT_NAME.xcarchive"
readonly DERIVED_DATA="$BUILD_DIR/DerivedData"
readonly EXPORT_DIR="$BUILD_DIR/export"
readonly DMG_NAME="${DMG_BASENAME}-${version}${build_suffix}.dmg"
readonly DIST_DMG="$output_dir/$DMG_NAME"
readonly DIST_SHA="$DIST_DMG.sha256"

notary_args=(--keychain-profile "$notary_profile")
if [[ -n "$notary_keychain" ]]; then notary_args+=(--keychain "$notary_keychain"); fi

# ---------------------------------------------------------------- generic helpers

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1${2:+ ($2)}"
}

# run_logged <log name> <command...>: output goes to logs/<name>.log; the tail is shown on failure.
run_logged() {
  local name="$1"; shift
  local log="$LOG_DIR/$name.log"
  if ! "$@" >"$log" 2>&1; then
    printf '\n--- last %s lines of %s ---\n' "$LOG_TAIL_LINES" "$log" >&2
    tail -n "$LOG_TAIL_LINES" "$log" >&2
    die "$name failed (full log: $log)"
  fi
}

# Python helper for plist and JSON checks (stdlib only, isolated mode).
readonly PY_HELPER='
import base64, hashlib, json, os, plistlib, sys

def load_plist(path):
    with open(path, "rb") as handle:
        data = handle.read()
    return plistlib.loads(data) if data.strip() else {}

def profile(path, cert_dir):
    p = load_plist(path)
    ents = p.get("Entitlements", {})
    certs = []
    for der in p.get("DeveloperCertificates", []):
        sha1 = hashlib.sha1(der).hexdigest().upper()
        certs.append(sha1)
        with open(os.path.join(cert_dir, sha1 + ".der"), "wb") as handle:
            handle.write(der)
    expires = p.get("ExpirationDate")
    print("name=" + str(p.get("Name", "")))
    print("uuid=" + str(p.get("UUID", "")))
    print("team=" + str((p.get("TeamIdentifier") or [""])[0]))
    print("appid=" + str(ents.get("com.apple.application-identifier", "")))
    print("expires=" + (expires.strftime("%Y-%m-%dT%H:%M:%SZ") if expires else ""))
    print("platforms=" + ",".join(p.get("Platform", [])))
    print("all_devices=" + ("true" if p.get("ProvisionsAllDevices") else "false"))
    print("keychain_groups=" + " ".join(ents.get("keychain-access-groups", [])))
    print("certs=" + " ".join(certs))

def entitlements(path, mode, team, bundle):
    e = load_plist(path)
    problems = []
    if e.get("com.apple.security.get-task-allow"):
        problems.append("com.apple.security.get-task-allow is set (debug entitlement)")
    groups = e.get("keychain-access-groups", [])
    expected = team + "." + bundle
    if mode == "signed":
        if expected not in groups:
            problems.append("keychain-access-groups does not contain " + expected)
        if e.get("com.apple.application-identifier") != expected:
            problems.append("com.apple.application-identifier is not " + expected)
        if e.get("com.apple.developer.team-identifier") != team:
            problems.append("com.apple.developer.team-identifier is not " + team)
    else:
        if "keychain-access-groups" in e:
            problems.append("keychain-access-groups is present in an ad-hoc build")
        if "com.apple.application-identifier" in e:
            problems.append("com.apple.application-identifier is present in an ad-hoc build")
    if e.get("com.apple.security.app-sandbox") is True:
        problems.append("com.apple.security.app-sandbox is true (FX Vault ships unsandboxed, D15)")
    for problem in problems:
        print(problem)
    return 1 if problems else 0

def json_field(path, key):
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle).get(key, "")
    except (OSError, ValueError, AttributeError):
        value = ""
    print(value if value is not None else "")

def notary_issues(path):
    try:
        with open(path, encoding="utf-8") as handle:
            log = json.load(handle)
    except (OSError, ValueError):
        print("(notary log unreadable)")
        return
    print("status: " + str(log.get("status", "")) + " - " + str(log.get("statusSummary", "")))
    for issue in (log.get("issues") or [])[:40]:
        print("  " + str(issue.get("severity", "")) + ": " + str(issue.get("path", "")) + ": " + str(issue.get("message", "")))

command = sys.argv[1]
if command == "profile":
    profile(sys.argv[2], sys.argv[3])
elif command == "entitlements":
    sys.exit(entitlements(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]))
elif command == "json-field":
    json_field(sys.argv[2], sys.argv[3])
elif command == "notary-issues":
    notary_issues(sys.argv[2])
else:
    sys.exit("unknown helper command " + command)
'
py() { /usr/bin/python3 -I -c "$PY_HELPER" "$@"; }

# kv_get <file> <key>: value of a key=value line written by the Python helper.
kv_get() { sed -n "s/^$2=//p" "$1" | head -n 1; }

plist_raw() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------- preflight

check_tools() {
  local tool
  for tool in xcodebuild xcrun codesign security ditto hdiutil plutil lipo shasum git; do
    require_tool "$tool"
  done
  [[ -x /usr/bin/python3 ]] || die "/usr/bin/python3 is missing (install the Xcode command line tools)"
  [[ -x /usr/libexec/PlistBuddy ]] || die "/usr/libexec/PlistBuddy is missing"
  require_tool xcodegen "brew install xcodegen; version pinned in .xcodegen-version"
  local expected installed
  expected="$(sed -n 1p "$ROOT/.xcodegen-version")"
  installed="$(xcodegen --version | awk '{print $NF}')"
  [[ "$installed" == "$expected" ]] || die "XcodeGen $installed is installed; .xcodegen-version pins $expected"
  [[ -x "$ROOT/scripts/make-dmg.sh" ]] || die "scripts/make-dmg.sh is missing or not executable"
  if [[ "$mode" == "signed" ]]; then
    require_tool spctl
    require_tool openssl
    [[ -f "$EXPORT_OPTIONS_TEMPLATE" ]] || die "missing $EXPORT_OPTIONS_TEMPLATE"
    if [[ "$notarize" == true ]]; then
      xcrun --find notarytool >/dev/null 2>&1 || die "xcrun notarytool not found (Xcode 13 or later)"
      xcrun --find stapler >/dev/null 2>&1 || die "xcrun stapler not found"
    fi
  fi
  if [[ "$publish" == true ]]; then
    require_tool gh "brew install gh"
  fi
  note "Xcode: $(xcodebuild -version | head -n 1), XcodeGen $installed"
}

working_tree_is_clean() {
  [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]]
}

check_git() {
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT is not a git repository"
  if [[ "$require_clean" == true ]]; then
    working_tree_is_clean \
      || die "the working tree has uncommitted or untracked changes:
$(git -C "$ROOT" status --porcelain --untracked-files=normal | head -n 20)"
    pass "working tree is clean"
  fi
  if [[ -z "$build_number" ]]; then
    git -C "$ROOT" rev-parse --verify --quiet HEAD >/dev/null \
      || die "no commits yet, so there is no default build number: pass --build-number <n>"
    if [[ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" == "true" ]]; then
      die "shallow clone: the commit count is wrong; fetch full history or pass --build-number"
    fi
    build_number="$(git -C "$ROOT" rev-list --count HEAD)"
  fi
  note "version $version (CFBundleShortVersionString $marketing_version, CFBundleVersion $build_number)"
}

check_publish_target() {
  local tag="v$version" local_ref remote_ref
  gh auth status --hostname github.com >/dev/null 2>&1 || die "gh is not logged in to github.com (gh auth login)"
  local_ref="$(git -C "$ROOT" rev-parse --verify --quiet "refs/tags/$tag" || true)"
  [[ -n "$local_ref" ]] || die "tag $tag does not exist locally (git tag -a $tag -m 'FX Vault $version')"
  [[ "$(git -C "$ROOT" rev-parse "$tag^{commit}")" == "$(git -C "$ROOT" rev-parse HEAD)" ]] \
    || die "tag $tag does not point at HEAD: check out the tag before building"
  remote_ref="$(gh api "repos/$repo/git/ref/tags/$tag" --jq .object.sha 2>/dev/null || true)"
  [[ -n "$remote_ref" ]] || die "tag $tag is not on $repo yet (git push origin $tag)"
  [[ "$remote_ref" == "$local_ref" ]] || die "tag $tag on $repo differs from the local tag"
  if gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name' 2>/dev/null \
      | grep -qxF "$DMG_NAME"; then
    die "release $tag on $repo already has $DMG_NAME (releases are immutable: bump the version)"
  fi
  pass "tag $tag is pushed to $repo and is HEAD"
}

check_local_xcconfig() {
  [[ -f "$LOCAL_XCCONFIG" ]] \
    || die "Config/Local.xcconfig is missing. Create it with: cp Config/Local.xcconfig.example Config/Local.xcconfig"
  grep -Eq '^[[:space:]]*#include\??[[:space:]]+"Signed\.xcconfig"' "$LOCAL_XCCONFIG" \
    || die "Config/Local.xcconfig must include Signed.xcconfig (see Config/Local.xcconfig.example)"
  pass "Config/Local.xcconfig includes Signed.xcconfig"
}

generate_project() {
  run_logged xcodegen xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
  pass "xcodegen generate"
  if [[ "$require_clean" == true ]]; then
    working_tree_is_clean || die "xcodegen generate changed the project: commit the regenerated FXVault.xcodeproj"
  fi
}

load_build_settings() {
  run_logged build-settings xcodebuild -project "$PROJECT" -target "$TARGET" -configuration Release \
    -showBuildSettings
}

build_setting() {
  awk -v key="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, key " = ") == 1 { print substr(line, length(key) + 4); exit }
  ' "$LOG_DIR/build-settings.log"
}

check_signed_build_settings() {
  local team identity entitlements bundle
  load_build_settings
  team="$(build_setting DEVELOPMENT_TEAM)"
  identity="$(build_setting CODE_SIGN_IDENTITY)"
  entitlements="$(build_setting CODE_SIGN_ENTITLEMENTS)"
  bundle="$(build_setting PRODUCT_BUNDLE_IDENTIFIER)"
  profile_specifier="$(build_setting PROVISIONING_PROFILE_SPECIFIER)"
  [[ "$team" == "$team_id" ]] || die "DEVELOPMENT_TEAM is '$team', expected $team_id (is Signed.xcconfig included?)"
  [[ "$identity" == "Developer ID Application"* ]] || die "CODE_SIGN_IDENTITY is '$identity', expected Developer ID Application"
  [[ "$entitlements" == "$SIGNED_ENTITLEMENTS" ]] || die "CODE_SIGN_ENTITLEMENTS is '$entitlements', expected $SIGNED_ENTITLEMENTS"
  [[ "$bundle" == "$BUNDLE_ID" ]] || die "PRODUCT_BUNDLE_IDENTIFIER is '$bundle', expected $BUNDLE_ID"
  [[ -n "$profile_specifier" ]] || die "PROVISIONING_PROFILE_SPECIFIER is empty (set it in Signed.xcconfig or Local.xcconfig)"
  pass "signed build settings (team $team_id, profile '$profile_specifier')"
}

# Decodes one profile into $WORK_DIR/profile-info (key=value) and its certificates into $WORK_DIR/certs.
decode_profile() {
  local file="$1"
  rm -rf "$WORK_DIR/certs" && mkdir -p "$WORK_DIR/certs"
  security cms -D -i "$file" >"$WORK_DIR/profile.plist" 2>/dev/null || return 1
  py profile "$WORK_DIR/profile.plist" "$WORK_DIR/certs" >"$WORK_DIR/profile-info"
}

installed_profiles() {
  local dir
  for dir in "$XCODE_PROFILE_DIR" "$LEGACY_PROFILE_DIR"; do
    [[ -d "$dir" ]] || continue
    find "$dir" -maxdepth 1 -type f \( -name '*.provisionprofile' -o -name '*.mobileprovision' \) -print
  done
}

# Sets profile_file, profile_uuid and profile_name.
resolve_profile() {
  local wanted="${profile_arg:-$profile_specifier}" file now name uuid expires best_expires=""
  profile_file=""
  if [[ -f "$wanted" ]]; then
    decode_profile "$wanted" || die "cannot decode provisioning profile $wanted"
    uuid="$(kv_get "$WORK_DIR/profile-info" uuid)"
    name="$(kv_get "$WORK_DIR/profile-info" name)"
    [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || die "$wanted has no valid UUID"
    if [[ "$name" != "$profile_specifier" && "$uuid" != "$profile_specifier" ]]; then
      die "profile file '$name' ($uuid) is not the one the build uses ('$profile_specifier'). Set PROVISIONING_PROFILE_SPECIFIER = $uuid in Config/Local.xcconfig"
    fi
    if [[ ! -f "$XCODE_PROFILE_DIR/$uuid.provisionprofile" ]]; then
      mkdir -p "$XCODE_PROFILE_DIR"
      cp "$wanted" "$XCODE_PROFILE_DIR/$uuid.provisionprofile"
      note "installed the profile into $XCODE_PROFILE_DIR"
    fi
    wanted="$uuid"
  elif [[ -n "$profile_arg" && "$profile_arg" != "$profile_specifier" ]]; then
    die "--profile '$profile_arg' differs from the build's PROVISIONING_PROFILE_SPECIFIER '$profile_specifier'. Set it in Config/Local.xcconfig instead"
  fi

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  while IFS= read -r file; do
    decode_profile "$file" || continue
    name="$(kv_get "$WORK_DIR/profile-info" name)"
    uuid="$(kv_get "$WORK_DIR/profile-info" uuid)"
    [[ "$name" == "$wanted" || "$uuid" == "$wanted" ]] || continue
    expires="$(kv_get "$WORK_DIR/profile-info" expires)"
    if [[ "$expires" < "$now" ]]; then
      warn "skipping expired profile $uuid ($expires)"
      continue
    fi
    if [[ -n "$profile_file" ]]; then
      warn "more than one installed profile matches '$wanted'; using the one that expires last"
    fi
    if [[ -z "$profile_file" || "$expires" > "$best_expires" ]]; then
      profile_file="$file"
      best_expires="$expires"
    fi
  done < <(installed_profiles)

  [[ -n "$profile_file" ]] || die "no valid provisioning profile '$wanted' is installed. Download 'FX Vault Developer ID' from developer.apple.com (Certificates, IDs & Profiles > Profiles) and double-click it, or pass --profile /path/to/profile.provisionprofile"
  decode_profile "$profile_file" || die "cannot decode $profile_file"
  profile_uuid="$(kv_get "$WORK_DIR/profile-info" uuid)"
  profile_name="$(kv_get "$WORK_DIR/profile-info" name)"
}

validate_profile() {
  local info="$WORK_DIR/profile-info" team appid platforms all_devices groups
  team="$(kv_get "$info" team)"
  appid="$(kv_get "$info" appid)"
  platforms="$(kv_get "$info" platforms)"
  all_devices="$(kv_get "$info" all_devices)"
  groups="$(kv_get "$info" keychain_groups)"
  [[ "$team" == "$team_id" ]] || die "profile '$profile_name' belongs to team '$team', expected $team_id"
  [[ "$appid" == "$team_id.$BUNDLE_ID" ]] || die "profile '$profile_name' is for '$appid', expected $team_id.$BUNDLE_ID"
  [[ ",$platforms," == *",OSX,"* ]] || die "profile '$profile_name' is not a macOS profile (platforms: $platforms)"
  [[ "$all_devices" == "true" ]] || die "profile '$profile_name' is not a Developer ID profile (it lists devices)"
  [[ " $groups " == *" $team_id.* "* || " $groups " == *" $team_id.$BUNDLE_ID "* ]] \
    || die "profile '$profile_name' does not allow the keychain group $team_id.$BUNDLE_ID (enable Keychain Sharing on the App ID)"
  pass "profile '$profile_name' ($profile_uuid), expires $(kv_get "$info" expires)"
}

# Sets signing_identity to the SHA-1 of a valid Developer ID Application identity in the profile.
resolve_identity() {
  local candidates sha1 end_date end_epoch best_epoch=0
  candidates="$(security find-identity -v -p codesigning \
    | awk -v team="($team_id)\"" 'index($0, "\"Developer ID Application: ") && index($0, team) { print toupper($2) }' \
    | sort -u)"
  [[ -n "$candidates" ]] || die "no valid 'Developer ID Application: ... ($team_id)' identity in the keychain"
  signing_identity=""
  if [[ -n "$identity_arg" ]]; then
    sha1="$(printf '%s' "$identity_arg" | tr '[:lower:]' '[:upper:]')"
    grep -qxF "$sha1" <<<"$candidates" || die "identity $sha1 is not a valid Developer ID Application identity for $team_id"
    [[ -f "$WORK_DIR/certs/$sha1.der" ]] || die "identity $sha1 is not one of the certificates in profile '$profile_name'"
    signing_identity="$sha1"
  else
    while IFS= read -r sha1; do
      [[ -f "$WORK_DIR/certs/$sha1.der" ]] || continue
      end_date="$(openssl x509 -inform DER -in "$WORK_DIR/certs/$sha1.der" -noout -enddate | sed 's/^notAfter=//')"
      end_epoch="$(LC_ALL=C date -j -u -f '%b %e %T %Y %Z' "$end_date" +%s 2>/dev/null || echo 0)"
      if [[ "$end_epoch" -gt "$best_epoch" ]]; then
        best_epoch="$end_epoch"
        signing_identity="$sha1"
      fi
    done <<<"$candidates"
    [[ -n "$signing_identity" ]] \
      || die "none of the Developer ID identities in the keychain is in profile '$profile_name': regenerate the profile with your current certificate"
  fi
  pass "signing identity ${signing_identity:0:8}... (Developer ID Application, $team_id)"
}

check_notary_profile() {
  run_logged notary-preflight xcrun notarytool history "${notary_args[@]}" --output-format json
  pass "notarytool keychain profile '$notary_profile' works"
}

run_tests_if_requested() {
  if [[ "$run_tests" == true ]]; then
    step "Tests (scripts/ci-local.sh)"
    run_logged ci-local "$ROOT/scripts/ci-local.sh"
    pass "scripts/ci-local.sh"
  else
    note "tests skipped (--skip-tests)"
  fi
}

# ---------------------------------------------------------------- build

common_build_settings() {
  printf '%s\n' "ARCHS=$ARCHS_REQUIRED" "ONLY_ACTIVE_ARCH=NO" \
    "MARKETING_VERSION=$marketing_version" "CURRENT_PROJECT_VERSION=$build_number"
}

archive_app() {
  local settings=()
  while IFS= read -r line; do settings+=("$line"); done < <(common_build_settings)
  if [[ "$mode" == "adhoc" ]]; then
    # Command-line settings reach every target, package targets included, so the
    # entitlements path is absolute. No base entitlements: keeps get-task-allow out.
    settings+=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= OTHER_CODE_SIGN_FLAGS=
      "CODE_SIGN_ENTITLEMENTS=$ADHOC_ENTITLEMENTS" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
  fi
  run_logged archive xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED_DATA" \
    -disableAutomaticPackageResolution "${settings[@]}"
  [[ -d "$ARCHIVE/Products/Applications/$PRODUCT_NAME.app" ]] || die "the archive has no $PRODUCT_NAME.app"
  pass "archived $PRODUCT_NAME.xcarchive"
}

export_signed_app() {
  local options="$WORK_DIR/ExportOptions.plist"
  cp "$EXPORT_OPTIONS_TEMPLATE" "$options"
  /usr/libexec/PlistBuddy -c "Set :teamID $team_id" \
    -c "Set :signingCertificate $signing_identity" \
    -c "Set :provisioningProfiles:$BUNDLE_ID $profile_uuid" "$options"
  run_logged export xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$options"
  [[ -d "$EXPORT_DIR/$PRODUCT_NAME.app" ]] || die "export produced no $PRODUCT_NAME.app"
  mv "$EXPORT_DIR/$PRODUCT_NAME.app" "$EXPORT_DIR/$APP_NAME"
  app_path="$EXPORT_DIR/$APP_NAME"
  pass "exported and renamed to '$APP_NAME'"
}

copy_adhoc_app() {
  mkdir -p "$EXPORT_DIR"
  ditto "$ARCHIVE/Products/Applications/$PRODUCT_NAME.app" "$EXPORT_DIR/$APP_NAME"
  app_path="$EXPORT_DIR/$APP_NAME"
  pass "copied from the archive and renamed to '$APP_NAME'"
}

# ---------------------------------------------------------------- gates

gate_common() {
  local app="$1" executable archs arch info details flags
  run_logged codesign-verify codesign --verify --deep --strict --verbose=2 "$app"
  pass "codesign --verify --deep --strict"

  executable="$app/Contents/MacOS/$PRODUCT_NAME"
  [[ -f "$executable" ]] || die "missing executable $executable"
  archs="$(lipo -archs "$executable")"
  for arch in $ARCHS_REQUIRED; do
    [[ " $archs " == *" $arch "* ]] || die "the executable lacks $arch (has: $archs)"
  done
  pass "universal binary ($archs)"

  info="$app/Contents/Info.plist"
  [[ "$(plist_raw "$info" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || die "CFBundleIdentifier is not $BUNDLE_ID"
  [[ "$(plist_raw "$info" CFBundleShortVersionString)" == "$marketing_version" ]] \
    || die "CFBundleShortVersionString is '$(plist_raw "$info" CFBundleShortVersionString)', expected $marketing_version"
  [[ "$(plist_raw "$info" CFBundleVersion)" == "$build_number" ]] \
    || die "CFBundleVersion is '$(plist_raw "$info" CFBundleVersion)', expected $build_number"
  pass "Info.plist $BUNDLE_ID $marketing_version ($build_number)"
  gate_app_name "$app"

  details="$WORK_DIR/codesign-details.txt"
  codesign --display --verbose=4 "$app" >"$details" 2>&1 || die "codesign --display failed"
  flags="$(sed -n 's/^CodeDirectory .*flags=0x[0-9a-fA-F]*(\([^)]*\)).*/\1/p' "$details" | head -n 1)"
  [[ ",$flags," == *",runtime,"* ]] || die "hardened runtime is off (flags: ${flags:-none})"
  pass "hardened runtime (flags: $flags)"

  codesign --display --entitlements - --xml "$app" >"$WORK_DIR/entitlements.plist" 2>/dev/null \
    || die "cannot read the app's entitlements"
}

# The menu bar and Finder show CFBundleName / CFBundleDisplayName. Xcode can add them back to
# InfoPlist.xcstrings ("FX Vault Dev" or a literal build-setting reference), and a localized
# value overrides the Info.plist one, so every place that can hold them must say DISPLAY_NAME.
gate_app_name() {
  local app="$1" key strings value
  for key in CFBundleName CFBundleDisplayName; do
    value="$(plist_raw "$app/Contents/Info.plist" "$key")"
    [[ "$value" == "$DISPLAY_NAME" ]] || die "Info.plist $key is '$value', expected '$DISPLAY_NAME'"
    for strings in "$app"/Contents/Resources/*.lproj/InfoPlist.strings; do
      [[ -f "$strings" ]] || continue
      plutil -extract "$key" raw -o - "$strings" >/dev/null 2>&1 || continue
      value="$(plist_raw "$strings" "$key")"
      [[ "$value" == "$DISPLAY_NAME" ]] \
        || die "${strings#"$app/"} localizes $key as '$value', expected '$DISPLAY_NAME' (remove it from App/Resources/InfoPlist.xcstrings)"
    done
  done
  pass "app name '$DISPLAY_NAME' (Info.plist and localized InfoPlist.strings)"
}

gate_entitlements() {
  local app_mode="$1" problems
  if ! problems="$(py entitlements "$WORK_DIR/entitlements.plist" "$app_mode" "$team_id" "$BUNDLE_ID")"; then
    printf '%s\n' "$problems" >&2
    die "entitlement gate failed"
  fi
}

gate_signed_app() {
  local app="$1"
  local details="$WORK_DIR/codesign-details.txt" embedded="$app/Contents/embedded.provisionprofile"
  gate_common "$app"
  gate_entitlements signed
  pass "entitlements: keychain-access-groups $team_id.$BUNDLE_ID, no get-task-allow"

  grep -q "^Authority=Developer ID Application: .*($team_id)$" "$details" \
    || die "the app is not signed by a Developer ID Application certificate of $team_id"
  grep -qx "TeamIdentifier=$team_id" "$details" || die "the signature's TeamIdentifier is not $team_id"
  grep -q '^Timestamp=' "$details" || die "the signature has no secure timestamp"
  pass "Developer ID Application ($team_id) with a secure timestamp"

  [[ -f "$embedded" ]] || die "the app has no Contents/embedded.provisionprofile (Touch ID would crash at launch, D14)"
  decode_profile "$embedded" || die "cannot decode the embedded profile"
  [[ "$(kv_get "$WORK_DIR/profile-info" team)" == "$team_id" ]] || die "the embedded profile's team is not $team_id"
  [[ "$(kv_get "$WORK_DIR/profile-info" uuid)" == "$profile_uuid" ]] || die "the embedded profile is not $profile_uuid"
  pass "embedded profile $profile_uuid (team $team_id)"
}

# Runs after stapling: `syspolicy_check distribution` requires the notarization ticket.
gate_distribution() {
  local app="$1"
  if command -v syspolicy_check >/dev/null 2>&1; then
    run_logged syspolicy-check syspolicy_check distribution "$app"
    pass "syspolicy_check distribution"
  else
    warn "syspolicy_check is unavailable (it ships with macOS 14 and later); skipped"
  fi
}

gate_adhoc_app() {
  local app="$1" details="$WORK_DIR/codesign-details.txt"
  gate_common "$app"
  gate_entitlements adhoc
  pass "entitlements: no keychain-access-groups, no get-task-allow"
  grep -qx "Signature=adhoc" "$details" || die "the app is not ad-hoc signed"
  [[ ! -e "$app/Contents/embedded.provisionprofile" ]] || die "an ad-hoc app must not embed a provisioning profile"
  pass "ad-hoc signature, no embedded profile"
}

# ---------------------------------------------------------------- notarization

# notarize <file> <label>: submits, waits, and fails with Apple's issue list unless Accepted.
notarize_file() {
  local file="$1" label="$2"
  local result="$LOG_DIR/notary-$label.json" status submission_id
  note "submitting $(basename "$file") to the notary service (this can take a few minutes)"
  xcrun notarytool submit "$file" "${notary_args[@]}" --wait --timeout "$NOTARY_TIMEOUT" \
    --output-format json >"$result" 2>"$LOG_DIR/notary-$label.err" || true
  status="$(py json-field "$result" status)"
  submission_id="$(py json-field "$result" id)"
  if [[ "$status" != "Accepted" ]]; then
    if [[ -n "$submission_id" ]]; then
      xcrun notarytool log "$submission_id" "${notary_args[@]}" "$LOG_DIR/notary-$label-log.json" \
        >/dev/null 2>&1 || true
      py notary-issues "$LOG_DIR/notary-$label-log.json" >&2 || true
    else
      tail -n "$LOG_TAIL_LINES" "$LOG_DIR/notary-$label.err" >&2 || true
    fi
    die "notarization of $label ended with status '${status:-unknown}' (submission ${submission_id:-none}; logs in $LOG_DIR)"
  fi
  pass "notarized $label (submission $submission_id)"
}

staple() {
  local file="$1" label="$2"
  run_logged "staple-$label" xcrun stapler staple "$file"
  run_logged "stapler-validate-$label" xcrun stapler validate "$file"
  pass "stapled and validated $label"
}

# spctl_gate <type> <file> <label>: Gatekeeper must accept the file as notarized Developer ID.
spctl_gate() {
  local type="$1" file="$2" label="$3"
  local log="$LOG_DIR/spctl-$label.log"
  spctl -a -vvv -t "$type" "$file" >"$log" 2>&1 || { cat "$log" >&2; die "Gatekeeper rejected $label"; }
  grep -qF "$GATE_NOTARIZED_SOURCE" "$log" || { cat "$log" >&2; die "Gatekeeper did not report '$GATE_NOTARIZED_SOURCE' for $label"; }
  pass "spctl -t $type: accepted, $GATE_NOTARIZED_SOURCE"
}

# ---------------------------------------------------------------- DMG and output

make_dmg() {
  local dmg="$1"
  rm -f "$dmg"
  run_logged make-dmg "$ROOT/scripts/make-dmg.sh" "$app_path" "$dmg" "$VOLUME_NAME"
  pass "DMG created and verified ($(basename "$dmg"))"
}

sign_dmg() {
  local dmg="$1"
  run_logged codesign-dmg codesign --force --sign "$signing_identity" --timestamp "$dmg"
  run_logged codesign-verify-dmg codesign --verify --strict --verbose=2 "$dmg"
  pass "DMG signed with the same Developer ID identity"
}

write_outputs() {
  local dmg="$1"
  mkdir -p "$output_dir" || die "cannot create output directory $output_dir"
  [[ ! -e "$DIST_DMG" ]] || die "$DIST_DMG already exists: remove it, or bump the version"
  cp "$dmg" "$DIST_DMG"
  (cd "$output_dir" && shasum -a 256 "$DMG_NAME" >"$DMG_NAME.sha256")
  (cd "$output_dir" && shasum -a 256 -c "$DMG_NAME.sha256" >/dev/null) || die "sha256 self-check failed"
  pass "wrote $DIST_DMG"
  pass "wrote $DIST_SHA ($(awk '{print $1}' "$DIST_SHA"))"
}

publish_release() {
  local tag="v$version" notes="$WORK_DIR/release-notes.md" create_args=()
  cat >"$notes" <<EOF
FX Vault $version, Developer ID signed and notarized (team $team_id).

Install with Homebrew:

    brew install --cask fractalx-technologies/tap/fx-vault

Or download $DMG_NAME and check it before opening:

    shasum -a 256 -c $DMG_NAME.sha256
    spctl -a -vvv -t install $DMG_NAME

Requires macOS 26 (Tahoe) or later and the GitHub CLI (gh) 2.97.0 or later.
EOF
  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    run_logged publish gh release upload "$tag" "$DIST_DMG" "$DIST_SHA" --repo "$repo"
  else
    create_args=(--repo "$repo" --verify-tag --title "FX Vault $version" --notes-file "$notes")
    if [[ "$prerelease" == true ]]; then create_args+=(--prerelease); fi
    run_logged publish gh release create "$tag" "$DIST_DMG" "$DIST_SHA" "${create_args[@]}"
  fi
  pass "published to https://github.com/$repo/releases/tag/$tag"
}

# ---------------------------------------------------------------- main

# The publish job's path: nothing is built, and the files must still match their checksum.
publish_existing() {
  step "Publish FX Vault $version from $output_dir"
  [[ -f "$DIST_DMG" && -f "$DIST_SHA" ]] || die "no $DMG_NAME to publish in $output_dir (and its .sha256)"
  (cd "$output_dir" && shasum -a 256 -c "$DMG_NAME.sha256" >/dev/null 2>&1) \
    || die "$DMG_NAME does not match $DMG_NAME.sha256"
  pass "$DMG_NAME matches its sha256"
  require_tool gh "brew install gh"
  check_git
  check_publish_target
  publish_release
}

main() {
  local dmg_work
  rm -rf "$BUILD_DIR"
  mkdir -p "$LOG_DIR" "$WORK_DIR"

  if [[ "$publish_only" == true ]]; then
    publish_existing
    return
  fi

  step "Preflight ($mode build of FX Vault $version)"
  [[ ! -e "$DIST_DMG" ]] || die "$DIST_DMG already exists: remove it, or bump the version"
  check_tools
  check_git
  if [[ "$publish" == true ]]; then check_publish_target; fi
  if [[ "$mode" == "signed" ]]; then
    check_local_xcconfig
    generate_project
    check_signed_build_settings
    resolve_profile
    validate_profile
    resolve_identity
    if [[ "$notarize" == true ]]; then check_notary_profile; fi
  else
    generate_project
  fi
  run_tests_if_requested

  step "Archive (Release, $ARCHS_REQUIRED)"
  archive_app

  if [[ "$mode" == "signed" ]]; then
    step "Export (Developer ID)"
    export_signed_app
    step "Gates: signed app"
    gate_signed_app "$app_path"
  else
    copy_adhoc_app
    step "Gates: ad-hoc app"
    gate_adhoc_app "$app_path"
  fi

  dmg_work="$BUILD_DIR/$DMG_NAME"
  if [[ "$mode" == "adhoc" ]]; then
    step "DMG (ad-hoc, not notarized)"
    make_dmg "$dmg_work"
    write_outputs "$dmg_work"
    step "Done"
    note "ad-hoc build: no Touch ID, and Gatekeeper asks for approval on first open (docs/RELEASING.md)"
    return
  fi

  if [[ "$notarize" == true ]]; then
    step "Notarize and staple the app"
    run_logged zip-app ditto -c -k --sequesterRsrc --keepParent "$app_path" "$WORK_DIR/$PRODUCT_NAME-app.zip"
    notarize_file "$WORK_DIR/$PRODUCT_NAME-app.zip" app
    staple "$app_path" app
    spctl_gate exec "$app_path" app
    gate_distribution "$app_path"
  fi

  step "DMG"
  make_dmg "$dmg_work"
  sign_dmg "$dmg_work"

  if [[ "$notarize" == false ]]; then
    step "Done (not notarized)"
    note "signed, gated, NOT notarized: $dmg_work"
    note "this DMG is for local verification only; nothing was written to $output_dir"
    return
  fi

  step "Notarize and staple the DMG"
  notarize_file "$dmg_work" dmg
  staple "$dmg_work" dmg
  spctl_gate install "$dmg_work" dmg

  step "Outputs"
  write_outputs "$dmg_work"

  if [[ "$publish" == true ]]; then
    step "Publish"
    publish_release
  fi

  step "Done"
  note "next: scripts/bump-cask.sh --tap <homebrew-tap checkout> $version $DIST_DMG"
}

main
