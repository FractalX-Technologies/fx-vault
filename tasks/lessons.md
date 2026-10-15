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

## 2026-10-15 - notarytool profile lookup
**Pattern:** `notarytool store-credentials` without `--keychain` worked once, then `--keychain-profile` lookups failed hours later ("No Keychain password item found").
**Rule:** always store and read the notary profile with `--keychain ~/Library/Keychains/login.keychain-db`; release-local.sh defaults to it.

## 2026-10-15 - Parallel feature agents duplicate shared UI
**Pattern:** Feature agents working in parallel each built their own branch-rule editor and sheet-size tokens (CreateRepo copied Environment's policy editor; four folders defined `Theme.Layout` extensions or local layout enums) because they could not edit shared folders.
**Rule:** Before parallel UI work, put shared editors and tokens in `App/Components` and `Helpers/Theme` first; the integrator merges any feature-local copy before release.

## 2026-10-15 - Shared scratchpad between agents
**Pattern:** Agents sharing one session scratchpad overwrote each other's generic build scripts (`snapbuild.sh`), so one agent briefly built another agent's snapshot.
**Rule:** Each agent keeps scratch files in its own subfolder (`<scratchpad>/<agent-name>/`) and names build dirs `.build-<agent-name>-*`.

## 2026-10-15 - Debug builds must not share the release bundle identifier
**Pattern:** Every Debug build registered with LaunchServices as "FX Vault" with `io.fractalx.fxvault`, so Spotlight or the Dock opened a Debug copy as if it were the real app. The owner created his first account in that copy (07:42), so it went into the separate `FX Vault Dev` vault. After `brew upgrade` the installed app correctly found no vault in `FX Vault` (that folder was born at 10:11, when he re-created the account), so the upgrade looked as if it had deleted his data. The first vault is intact in `FX Vault Dev/vault.sqlite` and opens only in a Debug build. A first write-up had the direction backwards (a Debug copy hiding a real vault); folder birth times and row timestamps showed the real order.
**Rule:** A build that opens different data must look like a different app: Debug is `io.fractalx.fxvault.dev` / "FX Vault Dev" with a DEV badge, set per configuration in project.yml, and `InfoPlist.xcstrings` must not localize `CFBundleName` / `CFBundleDisplayName` (a catalog value overrides the build setting). `BundleIdentityTests` guards it. Before stating the root cause of "my data disappeared", build the timeline from folder birth times (`stat`, `mdls`) and row timestamps read with `?immutable=1`, never from the symptom alone.
