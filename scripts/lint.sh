#!/usr/bin/env bash
# lint.sh - enforces the FX Vault code conventions (tasks/todo.md §4.6, §4.7).
#
# Scans Swift files in App/, Shared/ and Packages/FXVaultKit/Sources/ and fails on:
#   - try! and as!
#   - force unwraps after a call or subscript: `)!` and `]!` (including `URL(string: ...)!`)
#   - print( (use os.Logger; never log secret values)
#   - Capsule() (the SDK default has continuous, flattened ends; use the `.pill` shape)
#   - literal LAContext prompt strings: `localizedReason = "..."` or
#     `localizedFallbackTitle = "..."` (prompts are built with String(localized:) in the app)
#   - `import GRDB` / `import Clibsodium` outside the one module allowed to use each
#     (the app never imports either; D2, §4.2)
#   - `import VaultStore` in App/ or AppTests/ (the app reaches the database through VaultData)
#   - `@_spi(Testing) import` in App/ (test-only helpers such as ShareHoldRepository.hold and
#     SharingRepository.exportLegacyFile are for AppTests/ and the package tests)
#   - design tokens (docs/DESIGN.md), in App/ outside App/Helpers/Theme and App/Components/Design:
#     literal colors (Color(red:/white:/hue:), NSColor/CGColor component initializers, hex
#     helpers, #colorLiteral, named system colors such as .foregroundColor(.red) or Color.blue)
#     and literal fonts (Font.system(size:), .system(size:), Font.custom(, NSFont(name:),
#     NSFont.systemFont(ofSize:))
# Comment-only lines are ignored. Exit 0 when clean, 1 on any finding.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCAN_DIRS=(App Shared Packages/FXVaultKit/Sources)
failures=0

# rule_name|extended-regex
RULES=(
  'try! (use do/catch or try?)|try!'
  'as! (use as? with a guard)|(^|[^A-Za-z0-9_])as!'
  'force unwrap after a call: )!|\)!([^=]|$)'
  'force unwrap after a subscript: ]!|\]!([^=]|$)'
  'force-unwrapped URL(string:)|URL\(string:[^)]*\)!'
  'print( (use os.Logger)|(^|[^A-Za-z0-9_.])print\('
  'literal localizedReason / localizedFallbackTitle|localized(Reason|FallbackTitle)[[:space:]]*=[[:space:]]*"'
  'Capsule() (use the .pill shape: circular ends; docs/DESIGN.md)|Capsule\(\)'
)

existing_dirs=()
for dir in "${SCAN_DIRS[@]}"; do
  [[ -d "$dir" ]] && existing_dirs+=("$dir")
done
if [[ ${#existing_dirs[@]} -eq 0 ]]; then
  echo "lint: nothing to scan" >&2
  exit 0
fi

# Prints file:line:text for matches, skipping comment-only lines.
scan() {
  local pattern="$1"
  shift
  grep -rnE --include='*.swift' -- "$pattern" "$@" 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true
}

for rule in "${RULES[@]}"; do
  name="${rule%%|*}"
  pattern="${rule#*|}"
  hits="$(scan "$pattern" "${existing_dirs[@]}")"
  if [[ -n "$hits" ]]; then
    echo "lint: $name"
    echo "$hits" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
done

# Module import boundaries.
check_import() {
  local module="$1" allowed="$2"
  local hits
  hits="$(scan "^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(class |struct |enum |func |var |let )?${module}([[:space:]]|\.|$)" "${existing_dirs[@]}" \
    | grep -v "^${allowed}/" || true)"
  if [[ -n "$hits" ]]; then
    echo "lint: import ${module} is only allowed in ${allowed}/"
    echo "$hits" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
}
check_import GRDB Packages/FXVaultKit/Sources/VaultStore
check_import Clibsodium Packages/FXVaultKit/Sources/VaultCrypto

# The app target and its tests never import VaultStore (VaultSession.openLive/inMemory instead).
app_dirs=()
for dir in App AppTests; do
  [[ -d "$dir" ]] && app_dirs+=("$dir")
done
if [[ ${#app_dirs[@]} -gt 0 ]]; then
  hits="$(scan '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(class |struct |enum |func |var |let )?VaultStore([[:space:]]|\.|$)' "${app_dirs[@]}")"
  if [[ -n "$hits" ]]; then
    echo "lint: import VaultStore is not allowed in App/ or AppTests/ (use VaultData)"
    echo "$hits" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
fi

# Test-only SPI (`@_spi(Testing)`) is never imported by the app itself.
if [[ -d App ]]; then
  hits="$(scan '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*@_spi\(Testing\)' App)"
  if [[ -n "$hits" ]]; then
    echo "lint: @_spi(Testing) imports are for tests only, not App/"
    echo "$hits" | sed 's/^/  /'
    failures=$((failures + 1))
  fi
fi

# Design tokens: colors and fonts come from Theme (App/Helpers/Theme) and the design components
# (App/Components/Design) only.
DESIGN_ALLOWED='^App/(Helpers/Theme|Components/Design)/'
NAMED_COLORS='(red|blue|green|orange|yellow|purple|pink|gray|grey|black|white|brown|cyan|indigo|mint|teal)'
DESIGN_RULES=(
  'literal color: Color(red:/white:/hue:) or Color(.sRGB, ...)|Color\((red|white|hue|\.sRGB|\.displayP3|\.sRGBLinear)[:,]'
  'literal color: NSColor/CGColor component initializer|(NSColor|CGColor)\((red|white|hue|srgbRed|calibratedRed|calibratedWhite|calibratedHue|deviceRed|deviceWhite|displayP3Red|gray|genericGrayGamma2_2Gray):'
  'literal color: hex helper|(Color|NSColor|CGColor|\.init)\(hex:|#colorLiteral'
  "literal color: named system color|(foregroundColor|foregroundStyle|fill|stroke|strokeBorder|background|tint|accentColor|border|shadow)\\((color:[[:space:]]*)?(Color)?\\.${NAMED_COLORS}([^A-Za-z0-9_]|$)|Color\\.${NAMED_COLORS}([^A-Za-z0-9_]|$)|NSColor\\.(system)?(Red|Blue|Green|Orange|Yellow|Purple|Pink|Gray|Brown|Cyan|Indigo|Mint|Teal|red|blue|green|orange|yellow|purple|pink|gray|black|white|brown|cyan)([^A-Za-z0-9_]|$)"
  'literal font: Font.system(size:) / .system(size:)|(Font)?\.system\(size:'
  'literal font: Font.custom / NSFont(name:) / NSFont.systemFont(ofSize:)|Font\.custom\(|\.custom\("|NSFont\(name:|NSFont\.(monospacedSystemFont|systemFont|boldSystemFont)\(ofSize:'
)
if [[ -d App ]]; then
  for rule in "${DESIGN_RULES[@]}"; do
    name="${rule%%|*}"
    pattern="${rule#*|}"
    hits="$(scan "$pattern" App | grep -vE "$DESIGN_ALLOWED" || true)"
    if [[ -n "$hits" ]]; then
      echo "lint: $name (use Theme tokens or a design component; docs/DESIGN.md)"
      echo "$hits" | sed 's/^/  /'
      failures=$((failures + 1))
    fi
  done
fi

if [[ $failures -gt 0 ]]; then
  echo "lint: $failures rule(s) failed"
  exit 1
fi
echo "lint: OK"
