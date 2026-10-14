# Contributing to FX Vault

## Requirements

- macOS 14 or later with Xcode 26.6 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), at the version pinned in `.xcodegen-version`
  (only needed when you change `project.yml`)

## Project layout

`project.yml` is the source of truth for the Xcode project. The generated `FXVault.xcodeproj` is
committed, so you can open it directly. All non-UI code lives in the local Swift package
`Packages/FXVaultKit`. See [docs/STRUCTURE.md](docs/STRUCTURE.md) and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Build and test

```sh
# After changing project.yml (CI fails if the committed project drifts):
xcodegen generate

# Package tests (all modules):
swift test --package-path Packages/FXVaultKit

# App build and tests, ad-hoc signed:
xcodebuild test -project FXVault.xcodeproj -scheme FXVault -destination 'platform=macOS' CODE_SIGN_IDENTITY=-

# Everything CI checks, locally:
scripts/ci-local.sh
```

Contributor builds are ad-hoc signed and cannot use Touch ID; official releases are
Developer ID-signed.

## Conventions

- Swift 6 language mode. Code must build with Xcode 26.6 (no Swift 6.4-only features).
- No `try!`, `as!`, force unwraps or `print(`; `scripts/lint.sh` enforces this.
- Never put real secrets, tokens or account names in code, tests or fixtures.
