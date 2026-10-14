# FX Vault - Lessons

Patterns and rules learned from corrections during this project. Read at the start of every session.

<!-- Format: ## YYYY-MM-DD - short title / **Pattern:** what went wrong / **Rule:** what to do instead -->

## 2026-10-15 - XcodeGen parses `#include` inside xcconfig comments
**Pattern:** A comment in `Signed.xcconfig` spelled out an include line; XcodeGen 2.45.4 followed it, included the file into itself and segfaulted (exit 139).
**Rule:** Never write an include directive inside an xcconfig comment. Describe includes in prose ("includes Base") instead.

## 2026-10-15 - Redact for display, not before classifying
**Pattern:** Redacting a short stdin value ("v") out of gh stderr before classifying it turned "Must have admin rights" into "Must ha<redacted>e admin rights", so the error was classified as `.unexpected`.
**Rule:** Classify on token-pattern-redacted stderr only. Apply full value redaction only to the text that is shown or logged.

## 2026-10-15 - macOS /bin/bash 3.2 and dependent `local` declarations
**Pattern:** `local a="$1" b="$a/x"` fails with "unbound variable" under `set -u` on /bin/bash 3.2.
**Rule:** Declare dependent locals on separate lines. Check scripts with `/bin/bash -n` (3.2), not Homebrew bash.

## 2026-10-15 - `syspolicy_check` ordering
**Pattern:** `syspolicy_check distribution` fails until a notarization ticket is stapled, and `syspolicy_check notary-submission` rejects every un-notarized Developer ID app on macOS 27.
**Rule:** Run `syspolicy_check distribution` only after stapling; never use `notary-submission` as a pre-notarization gate.

## 2026-10-15 - Global `*.env` ignore swallows test fixtures
**Pattern:** `!**/Tests/Fixtures/*.env` did not match `Packages/FXVaultKit/Tests/EnvToolsTests/Fixtures/sample.env`, so the fixture would never be committed and CI would fail.
**Rule:** Every new fixture type that a global ignore could match gets checked with `git ls-files -o --exclude-standard` before handoff.

## 2026-10-15 - SQLite CHECK with NULL passes
**Pattern:** `CHECK (kdf_alg = 2 OR (... AND length(salt) = 16))` accepted a NULL salt, because `length(NULL) = 16` is NULL and a NULL CHECK passes.
**Rule:** In CHECK constraints, test `IS NOT NULL` explicitly before any comparison on a nullable column.

## 2026-10-15 - Names that shadow modules or the standard library
**Pattern:** A type named after its module (`VaultStore.VaultStore`) breaks qualified lookups, and a protocol named `Clock` hides the standard library's `Clock` in every importing module.
**Rule:** Never name a type after its module or after a standard-library type (`VaultRecordStore`, `VaultClock`).

## 2026-10-15 - No real identifiers in public fixtures or tests
**Pattern:** Tests used the real org, account and SSH alias names as sample data.
**Rule:** Use `owner-a`, `user-a`, `Example-Org`, `github-personal`. The GitHubKit fixture denylist test holds only SHA-256 digests of the names.
