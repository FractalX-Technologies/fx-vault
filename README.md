# FX Vault

A native macOS app for managing GitHub Actions secrets and variables across repositories,
environments and accounts, with a local encrypted vault and the GitHub CLI.

**Status: Beta.** Under active development; expect breaking changes before 1.0.

## Requirements

- macOS 14 Sonoma or later
- [GitHub CLI](https://cli.github.com) (`gh`) 2.97.0 or later

## Install

With Homebrew (installs `gh` too):

```sh
brew install --cask fractalx-technologies/tap/fx-vault
```

Or download `FXVault-<version>.dmg` from the GitHub Releases page, open it and drag
**FX Vault** to Applications.

### Verify a download

Each release ships `FXVault-<version>.dmg.sha256` next to the DMG. Releases are signed with a
Developer ID certificate and notarized by Apple:

```sh
shasum -a 256 -c FXVault-<version>.dmg.sha256
spctl -a -vvv -t install FXVault-<version>.dmg     # expect: accepted, source=Notarized Developer ID
xcrun stapler validate FXVault-<version>.dmg
```

`gh attestation verify` works only for releases built by the CI release workflow; releases
published from a maintainer's Mac carry no build attestation.

After installing, run `gh auth login` once if you have not used the GitHub CLI before.

## Building from source

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): modules, layers and public APIs
- [docs/DATABASE.md](docs/DATABASE.md): the local encrypted vault schema
- [docs/API.md](docs/API.md): every gh, git and ssh command the app runs
- [docs/SHARING-PROTOCOL.md](docs/SHARING-PROTOCOL.md): `.fxvault` files and nearby sharing
- [docs/RELEASING.md](docs/RELEASING.md): signing, notarization and the Homebrew cask

## Security

See [SECURITY.md](SECURITY.md) to report a vulnerability.

## License

MIT. See [LICENSE](LICENSE). Third-party components are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
