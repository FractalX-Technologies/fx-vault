#!/usr/bin/env bash
# lint.sh - enforces the FX Vault code conventions (tasks/todo.md §4.6, §4.7).
#
# Scans Swift files in App/ and Packages/FXVaultKit/Sources/ and fails on:
#   - try! and as!
#   - force unwraps after a call or subscript: `)!` and `]!` (including `URL(string: ...)!`)
#   - print( (use os.Logger; never log secret values)
#   - literal LAContext prompt strings: `localizedReason = "..."` or
#     `localizedFallbackTitle = "..."` (prompts are built with String(localized:) in the app)
#   - `import GRDB` / `import Clibsodium` outside the one module allowed to use each
#     (the app never imports either; D2, §4.2)
# Comment-only lines are ignored. Exit 0 when clean, 1 on any finding.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCAN_DIRS=(App Packages/FXVaultKit/Sources)
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

if [[ $failures -gt 0 ]]; then
  echo "lint: $failures rule(s) failed"
  exit 1
fi
echo "lint: OK"
