# Changelog

All notable changes to FX Vault are listed here. Versions follow `MAJOR.MINOR.PATCH`
(see [docs/RELEASING.md](docs/RELEASING.md)).

## 0.1.0 - Beta

First beta, for the FractalX team.

- Local encrypted vault: master password (Argon2id), one-time recovery key, field-level
  AES-GCM encryption, auto-lock, and Touch ID in the signed release.
- Every `gh` account, its organizations and their repositories in one sidebar.
- Repository and environment secrets and variables: add, edit, rename, convert, move, fill,
  revert and delete, then review and sync through `gh`.
- Environments: create, guided rename, duplicate, delete and edit deployment branch and tag
  rules. A policy change is blocked while GitHub lists reviewers, wait timers or app rules on
  that environment.
- Drift detection, interrupted-sync reconciliation at unlock, and write verification by
  re-listing GitHub.
- New repositories with environments, secrets and variables, cloned through an SSH alias.
- `.env` import and export, encrypted `.fxvault` sharing, and experimental nearby sharing.
