# FX Vault - Architecture

Status: domain and UI stages integrated (Milestones 1–6 package layers and every app screen).
Every package module is implemented and tested: VaultCore, VaultCrypto, VaultStore, GitHubKit,
EnvTools, SharingKit, **SyncEngine** (pure change model plus execution) and **VaultData** (vault
core plus the accounts, catalog, config, `.env`, sync, creation, drift and sharing repositories).
The app builds every repository in `AppContainer`, detects gh, shows `GHSetupScreen`, and runs the
three-column main window on live data (sidebar, scopes, detail table, toolbar and menu commands,
Preferences › Accounts, `.fxvault` open handling), and every feature sheet (item editor,
environments, sync, drift review, create repository, `.env` import/export, file and nearby
sharing) plugs in through one contract ("UI feature contract" below). Everything is verified by
view-model tests; the runtime checks a human must do are in [RELEASING.md](RELEASING.md). The
full design is in `tasks/todo.md` §4–§10; related documents:
[DATABASE.md](DATABASE.md), [API.md](API.md), [SECURITY-MODEL.md](SECURITY-MODEL.md),
[SHARING-PROTOCOL.md](SHARING-PROTOCOL.md), [RELEASING.md](RELEASING.md).

## Overview

FX Vault is a native SwiftUI app for macOS 14 and later. A local encrypted vault (GRDB/SQLite)
is the source of truth for GitHub Actions secrets and variables; every GitHub operation goes
through the GitHub CLI (`gh`).

- **App target `FXVault`**: screens, view models, AppKit-bound managers, the design system
  (`Helpers/Theme`) and the string catalogs. Never imports GRDB or Clibsodium.
- **Local package `FXVaultKit`**: every non-UI module, testable with `swift test`.

## Layers (FractalX MVVM)

```
SwiftUI [Name]Screen ──► @Observable [Name]ViewModel (MainActor)
                              │
                              ▼
               VaultData repositories (Sendable facades)
                              │
        ┌──────────┬──────────┼──────────────┬─────────────┐
        ▼          ▼          ▼              ▼             ▼
    Managers    Services    Stores        SyncEngine    SharingKit
    (local)     (gh, git)   (GRDB)        (pure domain) (protocol + transport)
```

View models depend only on repositories. A Store is a local manager over GRDB; SyncEngine and
SharingKit are pure domain services called by repositories.

## Module dependency graph (acyclic)

| Module | Depends on | Status | Responsibility |
|---|---|---|---|
| `VaultCore` | none | done | Models, typed ids, validation, `SecretBytes`, `VaultClock`, `Limits`, `Timeouts`, errors |
| `VaultCrypto` | VaultCore, Clibsodium | done | Argon2id, field encryption, key wrap, recovery key, keyring, password strength |
| `VaultStore` | VaultCore, GRDB | done | Database factory, migrations v1–v8, records, stores, observation. Stores blobs only |
| `GitHubKit` | VaultCore | done | Process runner, shell probe, gh locator/auth, command builders, scheduler, gh api for environments, ssh and git |
| `EnvTools` | VaultCore | done | .env parsing/serialization, key normalization, credential heuristics, secure file writes, iCloud and gitignore checks |
| `SharingKit` | VaultCore (+ CryptoKit, Network) | done | Share payload, `.fxvault` codec, passphrases, nearby protocol and transport, import planner. Key derivation is injected (`KeyDeriving`), so no VaultCrypto dependency |
| `SyncEngine` | VaultCore, VaultCrypto, GitHubKit | done | Change derivation, edit planning, summary, drift detection, preflight, planning, execution, verification, launch reconciliation. No database and no keys: VaultData plugs in through `SyncPersisting` and `SyncValueProviding` |
| `VaultData` | all of the above | done | `VaultSession`, `VaultManager`, `ReauthGate`, Touch ID, and the repositories view models use |

The `FXVaultKit` library product exposes VaultData, VaultCore, SyncEngine, SharingKit, EnvTools,
GitHubKit and VaultCrypto. VaultStore is internal to the package (reached through VaultData).
`scripts/lint.sh` fails if `import GRDB` appears outside VaultStore, `import Clibsodium`
outside VaultCrypto (only `Argon2id.swift` imports it), or `import VaultStore` in `App/` or
`AppTests/` (the app opens the vault with `VaultSession.openLive()` / `.inMemory()`).

`FXVaultTestSupport` (`Packages/FXVaultKit/Tests/FXVaultTestSupport`) is a test-only target that
no product contains: the stateful `GitHubSimulator` (over `FakeCommandRunner`, with the `GHMatch`
argv matchers) and `SteppingClock`, shared by SyncEngineTests and VaultDataTests.

## Cross-cutting rules

- **Secrets never become Strings when avoidable.** Values travel as `SecretBytes` (lock-protected,
  wiped on `wipe()` and `deinit`, redacted in every textual representation, constant-time `==`).
  Known unavoidable copies: `gh variable list` JSON decoding, Foundation JSON coders in
  SharingKit, CryptoKit key types. They are short-lived and documented at each site.
- **No plaintext values on disk.** The database stores AES-256-GCM blobs plus HMAC fingerprints.
- **Typed throws everywhere** (`throws(ValidationError)`, `throws(GHError)`, ...). Packages
  carry no user-facing text; the app maps errors to localized strings in `+Extension.swift` files.
- **Time is injected.** Anything that waits or reads the clock takes `any VaultClock`
  (`SystemClock` in the app, `ManualClock` in tests).
- **No magic numbers.** Sizes, counts and durations live in `Limits`, `Timeouts` (VaultCore),
  `EnvToolsLimits`, `GHConstants`, `NearbyProtocol`, `CryptoDomain` and `StoreConstants`.

## Concurrency

- App target: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency.
- Package: Swift 6 language mode, nonisolated by default, `MemberImportVisibility` enabled.
  Everything public is `Sendable`. Actors: `GHCommandScheduler` (one per account),
  `NearbySession`, `SyncExecutor` (one per run) and the VaultData repositories that do I/O
  (`GitHubEnvironmentRepository`, `RepoCatalogRepository`, `SyncRepository`,
  `RepoCreationRepository`, `DriftRepository`, `SharingRepository`, the nearby sender and
  receiver). Lock-protected classes: `SecretBytes`, `VaultKeyring`, `GHTokenCache`,
  `ManualClock`, `FakeCommandRunner`.
- Database writes are synchronous only (DATABASE.md, "Transactions").
- Argon2id is synchronous; callers (VaultData) run it in an `@concurrent` function off the main
  actor.
- Code must compile with Swift 6.3 (Xcode 26.6, the blocking CI toolchain). Only Swift 6.4 was
  available while building; no 6.4-only features are used.

## Module APIs

This is the contract for the next stage (the feature screens). Everything listed is
`public`.

### VaultCore

- **Ids:** `Identifier<Tag>` (UUID; `uuidString` lowercase for the database, `bytes` 16 raw
  bytes for the AAD; Codable as the string). Typealiases `RepoID`, `EnvironmentID`,
  `ConfigItemID`, `BranchPatternID`, `SharePackageID`, `SyncRunID`.
- **Models:** `AccountModel` (id = lowercase login), `RepoModel` (+ `OwnerType`,
  `RepoVisibility`, `RepoOrigin`, `ViewerPermission`, `RepoCreateSpecModel`),
  `RepoCapabilityModel` `.full | .repoLevelOnly | .readOnly(ReadOnlyReason)` with
  `WriteCollaboratorPolicy.default = .readOnly`, `EnvironmentModel` (computed fold keys and
  pending rename/policy flags), `DeploymentBranchPolicyModel` `.all | .protectedBranches |
  .custom([BranchPatternModel])` with `gitHubFlags`, `BranchPatternModel`, `ConfigItemModel`
  (never holds a value; `valueState`, `verifyState`, `provenance`, `shareOrigin`, `syncStatus`),
  `ConfigKind`, `ConfigScope` `.repository | .environment(EnvironmentID)`,
  `ConfigSyncStatus.derive(Facts)` (priority: deleted, blocked, added, modified (`willPush`
  when only `force_push` is set, v0.1.2), unverifiedShare, synced).
- **Validation** (all `throws(ValidationError)`): `PathSegmentValidator` (rejects `.`, `..`,
  `/`, `\`, control/bidi/zero-width characters and percent-encoded forms up to 4 levels),
  `GitHubNameValidator` (uppercases; `GITHUB_` prefix reserved; `suggestedFix`),
  `EnvironmentNameValidator` (NFC; `foldKey` = NFC → lowercased → NFC; `/` rejected),
  `RepoNameValidator`, `OwnerLoginValidator`, `GitHubHostValidator`, `BranchPatternValidator`,
  `DisplayNameSanitizer`, `NameAvailability`, `ScopeCapacityValidator` (100/100/500/100),
  `ValueNormalizer` (strips trailing CR/LF, D32; 48,000-byte limit), `UnicodeScalarPolicy`.
- **SecretBytes:** `init(count:)`, `init(copying:)`, `init(_ data:)`, `init(wipingSource:)`,
  `init(utf8:)`; `withUnsafeBytes`, `withUnsafeMutableBytes`, `copy()`, `prefix(_:)`,
  `utf8String()`, `wipe()`, `constantTimeEquals`. Neither Hashable nor Codable.
- **Clock:** `protocol VaultClock { now; uptime: Duration; sleep(for:) }`, `SystemClock`,
  `ManualClock` (`advance(by:)`, `setWallClock(to:)`, `waitForSleepers(count:)`).
- **Errors:** `ValidationError` (+ `NameRule`, `PathSegmentRule`), `VaultError` (wrongPassword,
  invalidRecoveryKey, locked, corrupted(VaultCorruption), biometryInvalidated,
  biometryUnavailable(reason), passwordRequired(reason), cancelled, passwordFallbackRequested,
  notInitialized, alreadyInitialized).
- **Constants:** `Limits` (value, name, throttle, gh, process-output, password, recovery, crypto,
  KDF, sharing and nearby limits), `Timeouts` (process, sync, drift, lock, clipboard, sharing
  durations), `Duration.timeInterval`.

### VaultCrypto

Key hierarchy (plan §5.1): a random 32-byte DEK per vault; HKDF-SHA256 derives K_field
(AES-256-GCM field encryption), K_fp (HMAC-SHA256 fingerprints) and the 16-byte key check value
(kcv). The DEK is wrapped twice: by Argon2id(password) and by HKDF(recovery key).

- **`UnlockedKeys`** is the only key surface (no public `SymmetricKey`): `generate(vaultID:)`,
  `init(dekBytes:context:)` (Touch ID path, verifies the kcv), `rotated()`, `seal(_:for:)`,
  `open(_:for:)`, `fingerprint(_:rowID:)`, `fingerprintMatches`, `exportDEK()`, `context`.
- **`VaultKeyring`**: `install(_:) -> generation`, `lock()` (synchronous), `withKeys { }`
  (copies the keys out, runs the body outside the lock; throws `.locked`),
  `ensureCurrent(generation)` before committing work started under older keys.
- **`KeyWrap`**: `wrap(_:password:policy:)` / `unwrap(_:password:context:policy:)` (NFC;
  bounds, layout, method and version checked **before** the KDF), and the recovery-key pair.
  `KeyWrapModel` maps to and from `key_wraps` columns. Wrong password → `.wrongPassword`; any
  malformed or out-of-bounds row → `.corrupted(...)`.
- **`KDFPolicy`**: `.production` (ops 3, 256 MiB; bounds ops 2–10, 64 MiB–1 GiB) and `.testing`
  (ops 1, 8 MiB; for tests and previews only). The composition root chooses.
- **Field encryption:** `FieldAAD.value(of:)` / `.syncedValue(of:)` bind table, column, row id,
  repository id, environment id, kind, name and DEK version; blob = `0x01 ‖ nonce ‖ ct ‖ tag`.
- **`RecoveryKey`**: 56 Crockford base32 characters (14 groups of 4) encoding 32 key bytes plus
  a 3-byte checksum; forgiving input (I/L/O, case, separators), canonical output.
- **`PasswordStrength.evaluate`**: local zxcvbn-style estimate; acceptable at ≥ 12 characters
  and ≥ 60 bits. No full English dictionary, so hand-picked word passphrases are overestimated.
- `Argon2id`, `Argon2idKeyDeriver: PasswordKeyDeriving`, `SecureRandom`, `CrockfordBase32`,
  `KeyHierarchy.generateVaultID()/generateSalt()`, `CryptoError`.

### VaultStore

See [DATABASE.md](DATABASE.md). `DatabaseFactory.openLive()/openOnDisk(directory:)/inMemory()`,
`VaultMigrator`, `VaultDatabase.read/write/checkpointTruncate`, records for every table, and the
stores `VaultRecordStore`, `AccountStore`, `RepoStore`, `ConfigStore`, `SyncJournalStore`,
`SharePackageStore`, each with convenience and `in tx:` forms plus `AsyncThrowingStream`
observation. `ConfigItemState` is the ciphertext-free projection; `RepoPendingInputsModel`
is the change-derivation input. All failures are `StoreError`.

### GitHubKit

See [API.md](API.md) for the command catalog.

- **Process:** `CommandRunning` (`ProcessRunner`, `FakeCommandRunner`), `CommandSpec`,
  `CommandResult`, `StdinPayload`, `EmptyWorkingDirectory`.
- **Environment:** `ShellEnvironmentResolver.resolve()` (interactive shell first, then login;
  v0.3.1), `ProcessEnvironmentBuilder.gh/git/ssh`, `ProcessIdentityModel`, `ShellEnvironmentModel`
  (plus `ghPath` from `command -v gh`, `setVariables: Set<ShellVariableName>` (names only),
  `probeMode: ShellProbeMode` `.interactive` / `.login` / `.failed`, `shellPath`,
  `exportedTokenVariables`).
- **gh:** `GHLocator.locate(overridePath:shell:trustedBinary:) -> GHInstallationModel` and
  `inspect(overridePath:shell:trustedBinary:checksEveryVersion:) -> GHLocatorReportModel`
  (v0.3.1: every candidate as `GHCandidateReportModel` with `GHCandidateSource`, rejection,
  `foreignOwner: GHBinaryOwnerModel`, version; the decisive candidate; the outcome), over
  `protocol GHFileInspecting` (`SystemGHFileInspector`; `FakeGHFileInspector` in `Testing/`),
  `GHTrustedBinaryModel` (consented trust), `GHVersion`, `GHAuthService` (`accounts()`,
  `listing() -> GHAccountListingModel` with `unusable: [GHUnusableAccountModel]`, `token(for:)`,
  `refreshToken`), `GHAccountStatusModel.tokenSource`, `GHTokenCache` (`purge()` on lock),
  `ScopeChecker`, `GHCommandService.execute`, `GHCommandScheduler` (typed operations for
  every §8 A–C row; serial per account; throttled; retries), `GHRepoRef`, `GHRepoCreateRequest`,
  DTOs (`GHRepoDTO`, `GHSecretDTO`, `GHVariableListingModel`, `GHEnvironmentDTO`,
  `GHBranchPolicyDTO`, `GHLicenseTemplateModel`), `GHWriteRecordModel` (throttle seed).
- **ssh/git:** `SSHConfigParser`, `SSHAliasValidator`, `SSHAliasResolver` (D1, D2),
  `GitService` (D3 clone, D4–D6).
- **Diagnostics** (v0.3.1): `GHDiagnosticsCollector(runner:identity:workingDirectory:fileInspector:)
  .collect(shell:overridePath:trustedBinary:) -> GHDiagnosticsModel` (Encodable, explicit nulls;
  runs only `gh --version` and A3; no token, no variable values), `GHDiagnosticsModel.unavailable`.
- **Testing:** `FakeCommandRunner` (`stub(executablePath:argumentsPrefix:with:)` for several gh
  binaries, `replaceStub`), `FakeGHFileInspector` (files, folders, symlinks, owners, `addHomebrewGH`).
- **Errors:** `GHError` (§8 E plus `untrustedBinary`, `invalidInput`, `forbiddenArgument`,
  `malformedOutput`, `outputTooLarge`, `writeBudgetExhausted`, `launchFailed`, `cancelled`;
  `logCode`, `isTransient`), `GitError`, `GHStderrClassifier`, `StderrRedactor`.
  `GHFailureContext.responseDetails` carries the `errors[]` details of a failed `gh api -i`
  body (gh prints only the top-level message on stderr; `APIResponseParser.errorDetails(in:)`,
  token-redacted, at most `GHConstants.maxErrorDetailCount`). They can only upgrade a
  `.validation` / `.unexpected` classification (plan, admin, write access, scope, SAML, rate
  limit, org policy), never turn a 422 into `.notFound`.
- Design notes: `posix_spawn` with its own process group and `CLOEXEC_DEFAULT`;
  `waitid(WNOWAIT)` before signalling; `GHCommand` can only be built inside GitHubKit.
- Deviation to confirm: `GHLocator` accepts a group-writable gh directory only for the `wheel`
  and `admin` groups (Homebrew's default on Apple Silicon); world-writable is always rejected.

### EnvTools

- **Parsing:** `DotEnvParser.parse(SecretBytes)` → `DotEnvParseResult` (entries in
  first-appearance order, last value wins; `EnvParseIssue` errors skip the line, warnings keep
  the entry; 8 MiB limit). An unquoted value that starts a PEM block (`-----BEGIN `) not closed
  on its line is an error (`.unquotedMultilineValue`): the block up to `-----END ` is skipped,
  so key material never becomes keys. A line without `=` (`.missingEquals`) carries no key,
  because its first token may be a value. `DotEnvSerializer.serialize(_:headerComments:)` picks the plainest
  quoting that reads back exactly (`parse(serialize(x)) == x`, property-tested).
- **Import:** `KeyNormalizer`, `CredentialClassifier.assess(key:value:)` (key patterns, URL
  userinfo, PEM, JWT, token prefixes, single-token entropy), `EnvImportPlanner.plan(_:)` →
  `EnvImportCandidateModel` (proposed name unique within the file, suggested kind, normalized
  value). `EnvImportPreviewModel.defaultSelections` (VaultData) leaves out candidates whose
  key had characters replaced or a leading digit fixed: the user opts in to those rows.
- **Files:** `SecureFileWriter.write(_:to:existingFile:)` (0600 from creation, refuses
  symlinks, exclusive rename, `F_FULLFSYNC`), `CloudSyncDetector.status(for:)`.
- **Git:** `protocol GitignoreChecker` (VaultData implements it over `GitService`),
  `GitExposureInspector.inspect(fileURL:using:)`, `GitignoreEditor`.

### SharingKit

See [SHARING-PROTOCOL.md](SHARING-PROTOCOL.md).

- **Package:** `SharePackageModel` (+ nested models, `ShareEntryID`), `SharePackageCoder`,
  `SharePackageValidator` (`.manifest` / `.payload`). Schema v1 and v2 (v2 adds partial
  environments: `ShareEnvironmentModel.deploymentBranchPolicy == nil`);
  `requiredSchemaVersion(for:)` picks the lowest version that holds the contents;
  `contentSummary -> ShareContentSummaryModel` gives counts per scope (never values).
- **File:** `FxVaultHeaderModel`, `FxVaultFileCodec(deriver:)` (`inspect`, `open`, `seal`,
  `encrypt`, `decrypt`), `protocol KeyDeriving` (VaultData adapts Argon2id).
- **Passphrase:** `PassphraseGenerator.bundled()`, `generate()`, `normalize(_:)`.
- **Nearby:** `NearbyHandshake` (pure state machine), `NearbySession` (actor over a
  `NearbyTransport` and a `VaultClock`), `NWNearbyTransport` / `NWNearbyBrowser` (Network
  framework, peer-to-peer Wi-Fi enabled, `local.` domain only; `advertising(purpose:)`,
  `advertisingChat(displayName:)`, `registeredServiceNames` (the name Bonjour registered),
  `NWNearbyBrowser(purpose:)`), `InMemoryTransportPair` (tests, previews),
  `NearbyFailureTracker`, events and abort reasons. `NearbyPurpose` (`.share` / `.chat`) selects
  the Bonjour service type and the label prefix; the commit-reveal handshake, SAS, CONFIRM and
  encrypted channel live once in the internal `NearbyKeyExchange`, used by both protocols.
- **Chat** (`Chat/`, `fxvault-chat/v1`, SHARING-PROTOCOL.md §7):
  `NearbyChatSession(role:localName:transport:clock:)` actor with `events`
  (`AsyncStream<NearbyChatEvent>`: `incomingConnection` (responder), `peerConnected`, `sasReady`,
  `peerConfirmedSAS`, `verified`,
  `message(ChatMessageModel)`, `attachmentOffered(ChatAttachmentOfferModel)`,
  `attachmentDeclined`, `attachmentSent`, `attachmentReceived(id, SharePackageModel)`,
  `peerClosed`, `aborted(NearbyAbortModel)`) and `start`, `confirmSAS`, `rejectSAS`, `sendText`,
  `offerAttachment(manifest:payloadProvider:)`, `requestAttachment`, `declineAttachment`,
  `close`; `phase` (`NearbyChatPhase`), `ChatError`, `ChatTextSanitizer`. Since v0.4.0 (chat
  version 2, `NearbyChatProtocol.maxVersion`): `acceptsConfigurationAttachments` and
  `offerConfiguration(manifest:payloadProvider:)` (a whole repository or environment;
  `ChatConfigurationPayloadProvider` returns the offered manifest with its values), and an
  offer's `content` is `ChatAttachmentContentModel.item(kind:name:environmentName:)` or
  `.configuration(ChatConfigurationSummaryModel)`. Ephemeral: no message
  history, everything wiped on close, abort or disconnect. Chat limits and timers are
  `Limits.chatMessageBytes`, `chatAttachmentBytes`, `chatConfigurationAttachmentBytes`, `chatMaxOpenAttachments`,
  `chatMaxOffersPerChat`, `chatMaxPeerFramesPerFloodWindow`, `chatMaxUnansweredPings`,
  `chatMaxBlankLines`, `chatMaxMarksPerCharacter` and `Timeouts.chatKeepaliveInterval`,
  `chatIdle`, `chatFloodWindow`, declared in
  SharingKit (`Chat/NearbyChatProtocol.swift`) as extensions of the VaultCore enums.
- **Import:** `ShareImportPlanner.plan(_:mode:local:fingerprint:)` → `ShareImportPlanModel`
  (chips, default actions, policy differences, replay warnings, provenance). VaultData's
  `ShareImporter` applies it in one transaction.
- `ShareError` (one `.invalidFile` for every file read failure).

- Teammates (v0.5.0, `Team/`): `TeamProtocol`, `TeamService` (preamble), `TeamMessageType`;
  `TeamDeviceKeys` (generate, `secretBytes()`, `withNewAnnounceKey()`, `card(login:displayName:macName:)`),
  `TeamCardModel` (wire form, id check), `TeamDeviceID`; `TeamPseudonym` and `TeamPresenceMatcher`;
  `TeamPairingMachine` / `TeamPairingSession` (Add Teammate); `TeamSessionMachine` / `TeamSession`
  (`connect(to:keys:requests:transport:)`, `ping`, `answer`) with `TeamRequest` (`.ping`,
  `.updateCard`); `TeamRouter.route(_:)` (preamble), `PreambleTransport`, `WatchedTransport`;
  `NWTeamListener` (persistent, re-registering presence advertisement); `TeamChatIdentityModel`
  for chat version 3. `NearbyChannel` is the encrypted channel shared by every nearby protocol.
- Shared spaces (v0.6.0, `Space/`, SHARING-PROTOCOL.md §11): `SpaceProtocol`; models
  (`SpaceBindingModel`, `SpaceMemberModel`, `SpaceItemModel`, `SpaceSnapshotModel`,
  `SpaceVersionModel` with `hash`, `encoded()`, `decode`, `SpaceHeadModel`); `SpaceLog`
  (`verify`, `verifyGenesis`, `apply` → `SpaceStateModel`), `SpaceKeychain` (epoch keys from
  wraps, `exportKey`/`importKey`), `SpaceVersionBuilder` (`genesis`, `publish`, `members`,
  `snapshot(of:keychain:)`, `fingerprint`), `SpaceMarkerModel` (`make`, `encoded`, `decode`,
  `isSigned(by:)`) and `SpaceGate.decide`. In `Team/`: `TeamService.spaces`, the spaces messages
  of `TeamSessionMachine`, `TeamSession.syncSpaces(with:keys:exchanger:transport:)` and
  `answer(…service:exchanger:)` over `TeamSpaceExchanging`; `NWSpaceListener`,
  `RemoteSpaceBackoff` and `TeamRemoteAddressModel` (Q4).

### SyncEngine

Pure domain (§7) plus execution. It never touches the database or the keys: VaultData
implements its two seams. Everything is `public`, `Sendable`, and models are `Hashable` unless
noted. Folders: `Model/`, `Diff/`, `Drift/`, `Execution/` (+ `Execution/Testing/`).

**Inputs (snapshots).**
- `RepoSnapshotModel(repository: RepoModel, environments: [EnvironmentModel], items:
  [ConfigItemSnapshotModel])`: `environment(_:)`, `items(in: ConfigScope)`,
  `environmentNameKeys(excluding:) -> (taken, reserved)` (feed to
  `EnvironmentNameValidator.checkAvailability`).
- `ConfigItemSnapshotModel` mirrors `ConfigItemState` field by field (fingerprints as `Data`,
  never values); computed `hasValue`, `isSynced`, `nameKey`, `syncedNameKey`, `isRenamed`,
  `isValueChanged`, `hasPendingChange`, `syncFacts`. Build it with VaultData's
  `RepoSnapshotMapper` only.
- `RemoteSnapshotModel(local:repository:environments:fingerprint:)` from
  `RemoteScopeListingInputModel(secrets: [GHSecretDTO], variables: [GHVariableListingModel])` and
  `RemoteEnvironmentInputModel(environment:branchPolicies:listing:)`. The fingerprint closure
  (`(SecretBytes, ConfigItemID) -> Data`) runs once per listed variable per local row it can be
  compared with; the caller wipes the listed values. Lookups `environment(_:)`, `listing(_:)`;
  `ignoredEnvironmentNames` lists remote names the vault cannot hold.

**Keys.** `RemoteScopeKeyModel` (`.repository`, `.environment(named:)`; `journalKey` `repo` or
`env|<foldkey>`), `RemoteItemKeyModel(scope:kind:name:)` (`item|<kind>|<NAME>|repo|…`),
`ChangeTargetModel.journalKey` → `sync_journal.target_key`. All parse back from their keys.

**Change derivation (§7.1).** `ChangeSetBuilder.build(_:) -> ChangeSetModel`.
- `ConfigChangeModel{repositoryID, operation, kind, target, scope}`, id
  `<kind>:<target journalKey>`, `Comparable` in canonical order (kind-major).
- `ConfigChangeKind` raw value → `sync_journal.op`: `create_repository`, `upsert_environment`,
  `rename_environment`, `reconcile_branch_patterns`, `delete_environment`, `set_variable`,
  `set_secret`, `delete_variable`, `delete_secret` (`isDeletion`).
- `ConfigChangeOperation`: `.createRepository`, `.upsertEnvironment`, `.renameEnvironment`,
  `.reconcileBranchPatterns`, `.deleteEnvironment`, `.setItem(ItemSetChangeModel{…, reason:
  .added | .renamed(from:) | .modified | .forcePushed | .copiedForEnvironmentRename})`,
  `.deleteItem(ItemDeleteChangeModel{…, reason: .deleted | .renamed(to:) |
  .removedWithEnvironment})`; `operation.itemID`.
- `ChangeSetModel`: `changes` (executable, canonical order), `blocked: [BlockedChangeModel]`,
  `notes` (`.caseOnlyEnvironmentRename`), `pendingCount` (a rename or delete counts 1; an item
  rename counts 2), `deletionCount`, `isEmpty`, `allChanges`, key sets, `change(id:)`,
  `blocking(_:reason:)` (dependents cascade as `.dependsOn(changeID:)`).
- `ChangeBlockReason`: `.valueMissing`, `.renameNeedsValues([String])`, `.remoteChanged`,
  `.dependsOn(changeID:)`. `ChangeSetNormalizer` guarantees one final operation per remote key
  and that no key is both set and deleted.

**Editing rules (§7.1).** `ConfigItemEditPlanner(items:)`: `add`, `editValue`, `delete`,
`rename` (into a tombstone revives it), `revert`, `discardAll`,
`fill(_:pushOnNextSync:requestedAt:)`, `requestPush(_:requestedAt:)` (Push on Next Sync, live
synced secrets with a value only, else `.pushNotApplicable`), `move(_:kind:scope:)`
(Convert/Move). Revert, Discard all and a deletion clear `force_push` and
`forcePushRequestedAt`. Each returns `ItemEditOutcomeModel{items, mutations:
[ItemMutationModel .insert/.update/.remove], planner}` and a value source per row
(`ItemValueSourceModel` `.unchanged`, `.newValue`, `.newValueAsSynced`, `.syncedValue`,
`.movedFrom(id)`); throws `ItemEditError`.

**Summary (§7.2).** `ChangeSummaryBuilder.summarize([ChangeSetModel], writeBudget:) ->
ChangeSummaryModel{repositories: [RepoChangeSummaryModel], writeBudget, pendingCount,
blockedCount}` (names and counts only, never values). `ChangeSummaryRenderer.lines/render(_:
vocabulary:)` lays it out; the app supplies `ChangeSummaryVocabulary` (8 closures of localized
text) because packages ship no user-facing text.

**Drift (§7.7).** `DriftDetector.detect(local:remote:suppression:) -> [DriftModel]`.
- `DriftModel{repositoryID, kind, subject, isConflict, remoteUpdatedAt, keepLocal,
  acceptGitHub}`; `DriftKind`: variableModified, secretModified, remoteAdded, remoteDeleted,
  environmentAdded, environmentDeleted, environmentPolicyModified.
- Each resolution is a `DriftResolutionModel{option, effects: [DriftEffectModel],
  unavailableReason (.valueMissing | .conflictsWithPendingRename), followUp
  (.promptFillValue(id))}`; effects are descriptions VaultData applies in one transaction.
- `DriftSuppressionModel(journalTargetKeys:)` hides our own recent deletions (target keys of
  succeeded `SyncJournalCommand.deletions` rows). Rows still pending verification are skipped:
  run `WriteVerifier.pendingVerificationPass` first.
- `DriftDetector.isSameTimestamp(_:_:)` compares `updatedAt` within 1 ms
  (`SyncEngineConstants.timestampTolerance`): the database stores milliseconds, gh prints up to
  nanoseconds.

**Seams VaultData implements** (`Execution/SyncPersisting.swift`). All calls are synchronous.
- `protocol SyncPersisting`: `appendJournal(_:) -> SyncJournalEntryID` (an `in_flight` row before
  each gh write, and for the preflight B2 lookup), `commit(_ SyncCommitModel)` (journal outcomes
  plus `[SyncStateEffectModel]` in **one** transaction), `journalEntries(states:)`,
  `journalEntries(repositoryID:since:)`, `writeStartTimes(accountLogin:since:)`. Errors map to
  `SyncError.persistenceFailed` / `.locked`.
- `protocol SyncValueProviding`: `ensureUnlocked()`, `value(of:) -> SyncItemValueModel?` (nil =
  value missing), `fingerprint(_:rowID:)`.
- `SyncStateEffectModel` (the row effects; `InMemorySyncVault` is the reference
  implementation): `.repositoryCreated`, `.repositoryPlanGated`, `.environmentSynced`,
  `.environmentRenamed` (moved row plus a new tombstone row for the old identity),
  `.environmentDeleted`, `.patternsUnsynced`, `.patternSynced`, `.patternRemoved`,
  `.itemPreWriteBaseline`, `.itemPushed` (optionally detaching a tombstone for the old name;
  re-seals the synced value only when the value did not change during the run),
  `.itemVerified`, `.itemVerificationExpired(forcePush:)`, `.itemDeleted`.
- Journal models: `SyncJournalEntryModel`, `SyncJournalOutcomeState` (raw values =
  `sync_journal.state`), `SyncJournalCommand` (raw values = `sync_journal.command`, see
  DATABASE.md), `SyncCommitModel`.

**Execution (§7.3–§7.6).**
- `SyncSchedulerRegistry([GHCommandScheduler])`; `SyncThrottleSeeder.seed(_:from:clock:)` (once
  per scheduler; VaultData's `GitHubEnvironmentRepository` already does it).
- `SyncPreflight(schedulers:persistence:values:clock:writePolicy:).run(_ snapshots, runID:,
  scopeStatus:) -> SyncPreflightModel` (capability, name and value rules, scope capacity, the
  256 KB repository-variable warning, write budget, the pending-verification pass, D27 base
  checks via `RemoteBaseChecker`, and `.protectionRulesPresent` for a policy change on an
  existing environment that B3 lists with reviewers, wait timers or app rules). A secret push
  the user requested (`forcePushRequestedAt`) is blocked only by a GitHub change after the
  request (`ConfigItemSnapshotModel.isSecretChangedOnGitHub`, also used by `DriftDetector`).
  Throws only
  `.locked` / `.persistenceFailed`; gh failures become
  `SyncBlockedChangeModel{change, reason: SyncBlockReason}`.
- `SyncPlanner.plan(_:includeDeletions:spaceReason:) -> SyncPlanModel` with ordered `SyncStepModel`s:
  create, environment upserts, patterns, guided renames, scope writes (repository first,
  variables before secrets), item deletes, environment deletes.
- Shared spaces (v0.6.0): `protocol SyncSpaceCoordinating` (`sharedScopes`, `gate`, `claim`,
  `publish`, `confirmPublished`, `abandonClaim`), injected as `spaces:` into `SyncPreflight`
  (`run(…spaceTakeovers:)`; gates every shared scope it touches, `SyncBlockReason.space` /
  `.sharedEnvironment`, `RepoPreflightModel.spaces`) and `SyncExecutor` (claim and re-read before
  a shared scope's first write, publish and re-read after the repository's steps; warnings
  `.spaceNotPublished`, `.spaceForked`), and `SpaceClaimReconciler` (unfinished claims at
  unlock).
- `actor SyncExecutor(schedulers:persistence:values:clock:)`: `run(_ plan) -> SyncResultModel`
  (throws only `.alreadyRunning`), `nonisolated progress: AsyncStream<SyncProgressEventModel>`,
  `nonisolated cancel()` (stops after the command in flight). One gh command per item, values on
  stdin, journaled `in_flight` first; per-scope re-list right before the writes (D27 re-check,
  `pre_write_updated_at`) and verification right after (every 2 s for up to 60 s).
- `SyncResultModel{runID, repositories, stopReason, warnings}`; outcomes `.succeeded(.verified |
  .pending | .notApplicable)`, `.failed(SyncFailureReason)`, `.skipped(SyncSkipReason)`,
  `.blocked(SyncBlockReason)`; `SyncWarningModel` (`.valueNormalized`, `.foreignRulesChanged`,
  `.repositoryNotConfirmed`, `.cloneRequested`).
- `WriteVerifier` (`isSecretVerified`, `isVariableVerified`, `pendingVerificationPass(local:
  remote:failedChecks:countsMisses:)`), `SyncReconciler.reconcile(_:)` (launch reconciliation of
  `in_flight` / `indeterminate` rows by re-list, never by the local clock; a confirmed secret
  set records the journaled `SyncJournalPushModel` fingerprints, and guided-rename copies only
  close their rows),
  `DeletionPreviewLoader.load(_:)` (§7.5 live contents per environment).
- `SyncError`: `.locked`, `.persistenceFailed`, `.valueUnavailable`, `.accountUnavailable`,
  `.github(GHError)`, `.alreadyRunning`; `logCode`.
- `InMemorySyncVault` (`Execution/Testing`): in-memory `SyncPersisting` + `SyncValueProviding`
  for tests and previews; test data only.

### VaultData

The only layer view models talk to (besides VaultCore models and value types re-exported through
the `FXVaultKit` product). Everything is `Sendable`; repositories that do I/O are actors (call
them with `await`). Packages ship no user-facing text: the app maps every error.

**Session and vault core** (`Session/`, `Vault/`).
- `VaultSession`: the shared handle. `openLive()` / `inMemory()` (factories for the composition
  root), `databaseDirectory`, `isLocked`, `generation`, `context`, `ensureCurrent(_:)`,
  `withKeys { }`, `write { keys, tx in }` (one write transaction whose keys match the stored
  `vaults` row; commits only if no lock or rotation happened meanwhile), `read { keys, tx in }`.
  **Every ciphertext write goes through `write`, every decryption through `read`** (rotation
  safety). Only `VaultManager` installs or drops keys.
- `VaultManager(session:policy:biometricStore:capabilities:clock:onLock:)`: `state`
  (`.noVault`/`.locked`/`.unlocked`), `create(password:) -> RecoveryKey`, `unlock(password:)`,
  `unlockWithBiometrics(prompt:)`, `lock()` (Phase A, synchronous: keyring lock, `onLock`,
  `LAContext` invalidate), `checkpoint()` (Phase B), `passwordRequirement()`,
  `biometricUnlockStatus()`, `isBiometricsEnabled()`, `biometricsAvailability()`,
  `changePassword(current:new:rotate:)`, `resetWithRecoveryKey(_:newPassword:)` (always
  rotates), `rotateDEK(password:)`, `newRecoveryKey(password:)`, `enableBiometrics(password:)`,
  `disableBiometrics(password:)`, `resetVault(password:)`,
  `isBiometricsTurnedOffAutomatically` / `acknowledgeBiometricsTurnedOff()` (in memory: Touch ID
  turned itself off through an enrollment change, an invalidated, missing or foreign item, or a
  failed replacement; set wherever that is detected, including ReauthGate checks while unlocked;
  cleared by enable, disable, reset and an answered offer). Argon2id work is `@concurrent`. A weak
  new password throws `PasswordPolicyError.tooWeak`.
- `ReauthGate` (D30): `authorize(.export | .share | .nearbySend, with: .biometrics(prompt) |
  .password(String))`, `authorizeWithPassword(.newRecoveryKey | .changePassword |
  .disableTouchID | .rotateKey | .resetVault, password:)`; plus `authorizeEnvExport(with:
  session:) -> EnvExportAuthorizationModel` and `authorizeShare(_:with:session:) ->
  ShareAuthorizationModel`. Both authorizations are single-use and bound to the session and
  its key generation (shared core `ReauthTicket`).
- Touch ID: `BiometricPrompt(reason:fallbackTitle:)` (built by the app with `String(localized:)`),
  `protocol BiometricKeyStoring`, `KeychainManager(accessGroup:authManager:)`,
  `BiometricAuthManager`, `protocol BuildCapabilitiesProviding` / `BuildCapabilities`,
  `BiometricKeyAccount`. Prompt outcomes: `VaultError.cancelled` (nothing to show) and
  `.passwordFallbackRequested` ("Use Master Password", or a finger Touch ID did not recognize:
  focus the password field). `unlock(password:)` also turns Touch ID off when the enrollment
  changed since it was enabled (the item can never be read again).
- `--diagnose` probe: `protocol KeychainProbing` / `KeychainProbe(calls:)` (`run(accessGroup:) ->
  KeychainProbeResultModel{addStatus, deleteStatus, passed}`, `statusName(_:)`), over
  `protocol KeychainItemCalling` (add and delete only; `SystemKeychainItemCalls` is live). It
  adds and deletes one item with `KeychainManager`'s exact attributes under the service
  `io.fractalx.fxvault.diagnose`, after deleting every item of that service in the group
  (leftovers of an earlier run whose delete failed or was interrupted).
- Fakes in Sources (tests and previews): `FakeBiometricKeyStore`, `FakeBuildCapabilities`.
- `Argon2idSharingDeriver: KeyDeriving` (use with `FxVaultFileCodec`).

**Accounts** (`Accounts/`). `actor GitHubEnvironmentRepository(database:runner:identity:
workingDirectory:clock:tokenCache:shellPath:sshConfigParser:fileInspector:)` is the
`GHSchedulerProviding` for every other repository: `shellEnvironment(refresh:)`,
`detectGH(overridePath:trustedBinary:)` (keeps `lastDetection: GHLocatorReportModel?`),
`accounts()` (keeps `unusableAccounts: [GHUnusableAccountModel]`, never stored),
`diagnostics(overridePath:trustedBinary:) -> GHDiagnosticsModel` (no state change, no database),
`ownerName(for:)`, `recheck(login:)`, `scopeFixCommands(for:)`, `purgeTokens()` (synchronous),
`scheduler(for:)` (one per account, seeded from the journal), `sshHostEntries()`,
`mapSSHAlias(_:to:)`, `testSSHAlias(_:for:)`. Errors: `GitHubEnvironmentError`.

**Catalog** (`Catalog/`). `actor RepoCatalogRepository(session:schedulers:clock:)`:
`catalog(accountLogin:) -> AccountCatalogModel` (account → organizations → other owners; a SAML
or not-found owner is marked unavailable), `lookUpRepository(fullName:accountLogin:)`,
`importRepository(_:accountLogin:) -> RepoImportResultModel` (one transaction; unreadable
scopes and skipped names reported), `refreshRepository(_:)`, `removeFromVault(_:)`,
`observeRepositories()`. Errors: `RepoCatalogError`.

**Config** (`Config/`). `struct ConfigRepository(session:clock:writePolicy:)`; every mutation is
one `VaultSession.write` and throws `ConfigRepositoryError`.
- Environments: `createEnvironment(in:name:policy:)`, `renameEnvironment(_:to:) ->
  EnvironmentRenameKind` (`.unchanged`, `.local`, `.caseOnly`, `.recreateOnGitHub`),
  `deleteEnvironment(_:)`, `updateBranchPolicy(_:to:)`, `revertEnvironment(_:)`,
  `duplicateEnvironment(_:as:)`.
- Items: `addItem`, `editValue`, `renameItem`, `deleteItem`, `revertItem`,
  `fillValue(_:value:pushOnNextSync:)` (`pushOnNextSync` defaults to true since v0.1.2),
  `requestPush(_:)` (Push on Next Sync), `moveItem(_:toKind:scope:)`, `discardAll(repositoryID:)`,
  `reveal(_:) -> SecretBytes` (caller wipes). Values are normalized on entry (D32;
  `ItemWriteResultModel.didStripTrailingNewlines`).
- Reads and streams: `changeSet(repositoryID:)`, `scopes(repositoryID:)`, `pendingCounts()`,
  `observeRepositories()`, `observeScopes(repositoryID:)`, `observeItems(repositoryID:scope:)`
  (each model with its `linkCount`), `observePendingCounts()`.
- Copy and linked copies (v0.4.0, v0.4.1): `copyConflicts(_:to:repositoryID:)` and
  `copyItems(_:to:repositoryID:conflicts:)` take sources from any repository; `copyItems` links
  each copy to its source. `ConfigRepository+Links.swift`: `linkedCopies(of:) ->
  [LinkedCopyModel]` (the group's other live places with `LinkedValueComparison` `.same` /
  `.differs` / `.valueMissing` / `.unknown`, the sync status and `editBlock`), `unlink(_:)`, and
  `updateLinkedCopies(from:to:) -> Int` (one transaction, one `ItemEditBatch` per repository; a
  value-missing copy is filled with a push requested now).
- `RepoSnapshotMapper` is the only `ConfigItemState` → `ConfigItemSnapshotModel` mapping.

**Team** (`Team/`, v0.5.0). `struct TeamRepository(session:clock:)`: `deviceKeys()` (created on
first use), `teammates()`, `observeTeammates()`, `teammateCards()` (announce keys opened),
`addTeammate(_:)`, `applyCardUpdate(_:)`, `removeTeammate(id:)` (renews the announce key, marks
`needs_card_update`), `setMuted(_:teammate:)`, `markSeen(_:)`, `cardUpdateDelivered(to:)`.
Errors: `TeamRepositoryError`. `ChatRepository.makeConversation(…team:)` passes the teammate
identity to chat version 3. Since v0.6.0: `remoteAccess()`, `observeRemoteAccess()`,
`setRemoteAccess(_:isAllowed:address:)`, `markRemoteConnection(_:at:)` (Q4).

**Spaces** (`Spaces/`, v0.6.0). `struct SpaceRepository(session:schedulers:clock:)`, also the
app's `SyncSpaceCoordinating`: `spaces()`, `observeSpaces()`, `detail(_:)`,
`readiness(repositoryID:scope:)`, `share(repositoryID:scope:with:me:reason:)` (genesis and the
marker), `addMembers` / `removeMembers` (→ `SpaceRotationChecklistModel`), `history(_:)`,
`itemHistory(_:kind:name:)`, `value(_:version:kind:name:)`, `restore(…)`; peers:
`heads(sharedWith:)`, `version(_:of:for:)`, `receive(_:spaceID:from:)` (→
`SpaceReceiveOutcomeModel`). `SpaceSnapshotBuilder` (rows → snapshot) and
`SpaceSnapshotApplier` (snapshot → rows, drafts kept). Errors: `SpaceRepositoryError`.
`SyncRepository` and `DriftRepository` take it as `spaces:`.

**.env files** (`EnvFiles/`). `struct EnvFileRepository(session:gitignoreChecker:
cloudSyncDetector:fileWriter:clock:writePolicy:)`: `readFile(at:)`, `parse(_:)`,
`conflicts(for:in:repositoryID:scope:)`, `applyImport(_:selections:repositoryID:scope:)`,
`exportPreview(repositoryID:scope:)`, `inspectDestination(_:)`, `export(repositoryID:scope:to:
authorization:existingFile:headerComments:)` (0600, needs an `EnvExportAuthorizationModel`),
`addGitignoreEntry(relativePath:repositoryRoot:)`. `GitServiceGitignoreChecker(git:)`.

**Sync** (`Sync/`). `actor SyncRepository(session:schedulers:cloner:clock:writePolicy:)`:
`pendingSummary()` / `observePendingSummary()` (feeds "Sync N"), `prepareAfterUnlock()`
(journal pruning plus launch reconciliation; preflight also runs it once per key generation),
`preflight(repositoryIDs:scopeStatus:) -> SyncReviewModel{preflight, credentialWarnings}`,
`deletionPreview(for:)`, `startRun(_:includeDeletions:cloneFolder:) -> SyncRunHandle{progress,
cancel(), outcome(), isFinished}`, `currentRun`, `lastRunReport()` / `observeLastRunReport()`.
Internals: `VaultSyncPersistence` (only pushes need keys; other bookkeeping is recorded even
while locked), `VaultSyncValues`, `SyncEffectApplier`, `SyncRowWriter` (shared by sync effects,
drift resolutions and the repository import).

**Creation** (`Creation/`). `actor RepoCreationRepository(session:schedulers:git:clock:
writePolicy:): RepoCloning`: `stage(_ RepoCreationDraftModel)` (one transaction; one Sync then
creates everything), `discardStaged(_:)`, `checkAvailability(owner:name:accountLogin:)`,
`owners(accountLogin:)`, `gitignoreTemplates` / `licenseTemplates` (cached per account),
`clone(_:into:)` (through the mapped SSH alias; records `clone_path`).

**Drift** (`Drift/`). `actor DriftRepository(session:schedulers:clock:writePolicy:)`:
`detectOnOpen(_:)` (debounced, `Timeouts.driftDebounce`), `refresh(_:)`, `report(for:)`,
`reset()` (on lock), `resolve(_:option:)` (re-reads the scope; `.stale` when GitHub changed
again), `enterNewValue(_:value:pushOnNextSync:)`. Unreadable scopes are never reported as deleted.

**Sharing** (`Sharing/`). `actor SharingRepository(session:schedulers:deriver:clock:writePolicy:
fileWriter:)`: `previewExport(_:)`, `exportFile(_:to:senderName:appVersion:authorization:
existingFile:)` (passphrase returned once, file 0600), `readFile(at:)` (header checked before
any passphrase), `openFile(_:passphrase:checkGitHub:) -> ShareImportDraftModel`, `replan(_:
checkGitHub:)`, `apply(_:plan:confirmReplay:)` (re-plans inside the transaction;
`.planOutdated`), `makeNearbySender(transport:localName:clock:)`,
`makeNearbyReceiver(transport:localName:clock:)` (`NearbyShareSender` / `NearbyShareReceiver`
actors; the UI never receives values). What to share is a `ShareSelectionModel`: `.item`,
`.environment`, `.repository` or `.subset(ShareSubsetModel(repositoryID:environmentIDs:itemIDs:))`
(any combination; a branch policy travels only for the environments in `environmentIDs`, see
SHARING-PROTOCOL.md §1.2). `ShareExportPreviewModel.summary` holds the per-scope counts.

**Chat** (`Chat/`, v0.2.0). `struct ChatRepository(session:sharing:clock:)`:
`attachableItems() -> [ChatAttachableItemModel]` (live items with a value, names only, by
repository, then repository level before environments, kind and name) and
`makeConversation(role:transport:localName:clock:) -> NearbyChatConversation`. The
`NearbyChatConversation` actor wraps one `NearbyChatSession`: `events` (the session's events; a
received attachment is forwarded **without** its value), `start`, `confirmCode`, `rejectCode`,
`sendText`, `offerItem(_:senderName:appVersion:authorization:)` (consumes a
`ShareAuthorizationModel(.nearbySend)`; manifest from the share builder's `.item(id)`; the value
is decrypted only when the peer asks, and only if the item still has the offered name, kind and
scope), `requestAttachment`, `declineAttachment`, `previewAttachment(_:checkGitHub:) ->
ShareImportDraftModel` (moves the received value into a share import draft; apply it with
`SharingRepository.apply`), `discardAttachment`, `close()` (wipes every received value; aborts
and disconnects do too). Errors: `NearbyChatError` (`.chat(ChatError)`, `.sharing(SharingError)`,
`.valueMissing`, `.attachmentUnavailable`).
v0.4.0 (repositories in chat, SHARING-PROTOCOL.md §7.1): `ChatRepository.attachableRepositories()`
(repositories with environments or items, names and counts) and `importTargets()` (the vault's
repositories, for Import Into…); on the conversation `acceptsConfigurationAttachments`,
`offerRepository(_:senderName:appVersion:authorization:)` (checks the peer's version before it
consumes the `.nearbySend` authorization), `previewAttachment(_:into:checkGitHub:)` (`into`: plan
for another repository of this vault), `saveAttachment(_:to:authorization:)` (`.fileExport`;
`SharingRepository.exportFile(package:to:authorization:existingFile:)` seals the received
package; the package stays for an import) and `receivedPreview(_:)` (names and counts).

**Composition (`AppContainer`, `App/Composition/VaultDataComponents.swift`).**

```swift
let session = try VaultSession.openLive()                 // .inMemory() for previews and tests
let data = VaultDataComponents.make(session: session, runner: ProcessRunner(clock: clock),
    identity: .current(), workingDirectory: try EmptyWorkingDirectory.prepareDefault(), clock: clock)
// data.github owns the token cache; every other repository gets data.github as GHSchedulerProviding.
let vault = try VaultManager(session: session, policy: .production, biometricStore: keychain,
    capabilities: caps, clock: clock, onLock: { data.github.purgeTokens() })   // §5.8 Phase A
let reauth = ReauthGate(manager: vault)
// After every unlock (AppViewModel): await the gh probe, then try await data.sync.prepareAfterUnlock()
// Lock Phase B (AppViewModel): end SyncActivity, await data.sync.currentRun?.cancel(),
//   await data.drift.reset(), clear the clipboard, abort modals, checkpoint.
```

- One instance of each repository for the process (`VaultDataComponents`): `github`, `catalog`,
  `config`, `envFiles`, `sync`, `creation`, `cloner`, `drift`, `sharing`, `chat`.
- git needs the probed login-shell environment (PATH, `SSH_AUTH_SOCK`). `GitServiceProvider`
  resolves it on first use through `github.shellEnvironment()`; `ShellResolvingRepoCloner`
  (`RepoCloning`, also `sync`'s cloner) and `ShellResolvingGitignoreChecker` (`envFiles`) use it.
  `creation` is built with `git: nil` (staging, owners, templates, availability only): **clone
  through `cloner`**.
- `.preview` and `.test` use `VaultDataComponents.makeOffline(session:runner:clock:sandbox:)`: an
  in-memory session, a `FakeCommandRunner`, a home folder under the temporary directory (no
  `~/.ssh` read), never a real process.

### Integration rules

- Journal: `op` = `ConfigChangeKind.rawValue`, `command` = `SyncJournalCommand.rawValue`,
  `target_key` = `ChangeTargetModel.journalKey`, `error_code` = `GHError.logCode` or a
  `SyncExecutionConstants` code. Drift suppression reads
  `SyncJournalStore.fetchSucceeded(repositoryID:commands:since:)` with the raw values of
  `SyncJournalCommand.deletions`.
- Throttle seeding happens only in `GitHubEnvironmentRepository.scheduler(for:)` (seeding twice
  double counts).
- Run `SyncRepository.prepareAfterUnlock()` after every unlock, before Sync is offered.
- Every value write goes through `ConfigRepository` (or its internal `ItemEditBatch`), which
  re-seals `value_ct` whenever name, scope or kind change (the AAD binds them).
- Every value copy goes through `ClipboardManager`; every value entry uses `SecretValueEditor`.
- The sync view model holds a `SyncActivityAssertion` for the whole run (it suspends only the
  inactivity rule).
- Sheets that show values conform to `LockObserving` or live under a phase-switched screen.
- `.env` export needs `ReauthGate.authorizeEnvExport`; `.fxvault` export and nearby send need
  `ReauthGate.authorizeShare`.

### Decisions to confirm (domain and UI stages)

These depart from or refine the plan text (`tasks/todo.md`) and are implemented as described.

| # | Area | Decision |
|---|---|---|
| 1 | §7.7 | `DriftDetector.detect(local:remote:suppression:)`: fingerprinting moved to `RemoteSnapshotModel.init`, because fingerprints are tied to the row id |
| 2 | §7.7 | Secret "Keep local" also sets `remote_updated_at` to GitHub's value; otherwise D27 would block the force push forever |
| 3 | §7.7 | New drift kind `environmentPolicyModified` (D27 sends policy differences to Drift review) |
| 4 | §7.7 | `updatedAt` compared within 1 ms (database stores milliseconds) |
| 5 | §7.3 | Preflight D27 uses `RemoteBaseChecker`, the same rule as the executor's per-scope re-check, instead of `DriftDetector` |
| 6 | §7.3 | `pre_write_updated_at` comes from the executor's per-scope re-list, not from preflight |
| 7 | §7.6 | A guided rename posts all its branch patterns to the new environment |
| 8 | §7.3 | Pattern reconcile deletes every GitHub pattern not wanted locally (including a teammate's) |
| 9 | §7.1 | The delete half of an item rename runs only after its set is verified in the same run |
| 10 | §7.3 | Pending-verification miss counts are held in memory (`DriftRepository`); a relaunch restarts the count (no column) |
| 11 | §7.1 | Re-creating a deleted environment's name revives it with its synced items; duplicating into such a name is refused (`nameReservedByPendingChange`) |
| 12 | §7.6 | A synced environment's local rename is allowed and reported as `.recreateOnGitHub`; Sync performs the guided recreate |
| 13 | §7.1 | Deleting a synced environment keeps its item rows (removed with it on GitHub); Revert and Discard all are allowed on read-only repositories; environment edits need an unlocked vault |
| 14 | §5.13 | Credential-looking variables are one "push anyway?" confirmation for the whole run (`SyncPlanner` cannot drop a single change) |
| 15 | §7.7 | Drift resolutions re-read the subject's scope from GitHub (no listed values kept in memory) and fail with `.stale` when it changed again |
| 16 | §9.5 | A share import re-plans inside the write transaction (`.planOutdated`); an incoming variable without a value is skipped; an environment GitHub already lists is created as synced |
| 17 | M4 | Staged repositories record the viewer as admin until the next Sync confirms it; by-name owners not known as organizations are stored as `User` |
| 18 | §5.5 | `LAError.userFallback` maps to the new `VaultError.passwordFallbackRequested` (focus the password field) instead of `.cancelled` |
| 19 | §10 | A lock before a new recovery key is confirmed as saved wipes it and sets a persistent reminder banner; a recovery reset keeps the phase `.locked` until "I saved the new recovery key"; Reset vault is offered while locked and unlocked |
| 20 | §10.3 | `GHSetupScreen` offers **Not Now** (work on the local vault without gh until the next launch or until gh becomes ready); also shown for an untrusted gh binary and a failed probe |
| 21 | §10 Toolbar | Sync and New Repository are also disabled while gh is not ready (a run would fail at the first command) |
| 22 | §10.4 | Variables are decrypted for the visible scope so the table shows them in plaintext (§10); they are dropped on lock and scope change. Secrets stay masked until revealed |
| 23 | §5.10 | git (clone, `.env` export checks) uses the login-shell environment probed by the gh repository, resolved on first use; `RepoCreationRepository` is built without git and every clone goes through `ShellResolvingRepoCloner` |
| 24 | §10 | An empty "Personal" group is hidden until gh lists the account; accounts known only from the vault (gh no longer lists them) keep their repositories in the sidebar |
| 25 | §7.1 | Editing a secret starts with an empty field (empty keeps the current value); "Edit Current Value" decrypts it only on request. Variables open with their value |
| 26 | §7.1 | Convert or Move preselects the opposite kind; a secret with no value can only move as a secret |
| 27 | §7.1 | The fill choice is a two-option radio group with both labels ("Fill local value (already on GitHub)" default, "Push this value on next Sync"), shown only for secrets already on GitHub. **Superseded in v0.1.2** (decision 45) |
| 28 | §7.6 | Rename Environment is blocked in the sheet while a secret has no value (the repository would accept it and Sync would block later); "Enter Values…" opens the fill editor |
| 29 | M4 | Save in every branch policy editor (Environment Settings, New Environment, New Repository) waits for a typed but unadded rule, and Selected needs at least one rule in New Repository |
| 30 | M4 | The plan note shows for private repositories and for repositories GitHub already refused on plan grounds (`isEnvPlanGated`) |
| 31 | M4 | New Repository with "Clone to my Mac" on needs a clone folder before Create; the owner picker shows "(Personal)" / "(Organization)" (no organization role is available) |
| 32 | §5.12 | `.env` export runs the git checks once before writing and shows them after the write (the iCloud warning must come before it); a failed write uses up the Touch ID / password authorization |
| 33 | §5.12 | Pasted `.env` text is cleared as soon as it is parsed; Start Over returns to an empty paste box. **Superseded in v0.1.1:** paste mode parses live and keeps the text in the editor until the import, close or lock (bulk paste) |
| 34 | §9 | The share scope tree checks one node at a time (a package holds exactly one scope); checking a node includes everything under it. **Superseded in v0.2.0:** the tree is multi-select with tri-state checkboxes (a "Repository level" group, each environment, each item; any combination). An environment's branch policy is shared only when its checkbox is fully checked; a mixed environment shares only its checked items (schema v2 partial environment, SHARING-PROTOCOL.md §1.1–§1.2) |
| 35 | §7.3 | Clone in the Sync result is always offered for a failed or not-attempted clone; without a clone folder it asks for one (`ClonePanel`) |

### As built in v0.1.1 (bulk paste and Touch ID)

| # | Area | Decision |
|---|---|---|
| 36 | Bulk paste | ⌘V uses `onPasteCommand(of: [.plainText], validator:)` on the whole detail column (Paste is disabled in read-only scopes) and reads only the providers SwiftUI hands over; the empty table also shows a Paste Multiple… button. Paste Multiple… opens an empty, focused editor. Both open `.envImport` with `defaultKind` = the open tab and the open scope as target |
| 37 | Bulk paste | The pasted text reaches the sheet in `EnvPasteBuffer` (identity-hashed, redacted, taken once): the only context that carries a value (see UI feature contract) |
| 38 | Bulk paste | Paste mode has no Review step: the editor is parsed `Theme.Durations.envPasteParseDebounce` (300 ms) after the last edit on the injected `VaultClock`, off the main actor (a generation counter drops stale results), and Import waits for a pending parse. Explicit actions (prefill, Paste button, Clear) parse at once. Row edits are keyed by key-as-written plus occurrence so they survive re-parses; Mark All also applies to rows added later. Changing the target scope resets every conflict choice to Skip. The editor has its own coordinator (no D32 strip on focus loss, nothing written back after it is dismantled) |
| 39 | Bulk paste | A detail-table import starts every row as the tab's kind and only badges credential-looking variables ("Make Secret"); the toolbar Import .env (no `defaultKind`) keeps `CredentialClassifier`'s suggestion |
| 40 | Touch ID | The one-time offer is a sheet over the lock screen, answered before `didUnlock()` shows the main window, so it never competes with the main window's sheets (a pending `.fxvault` import). It is not offered after onboarding or a recovery reset |
| 41 | Touch ID | `errSecAuthFailed` without lockout maps to `.passwordFallbackRequested` (keeps the item); only `errSecItemNotFound` means invalidated. Enrollment changes are also caught from `biometry_state_hash`: a password unlock deletes the stale item and clears the enablement. The re-offer after a password unlock follows `VaultManager.isBiometricsTurnedOffAutomatically`, not the reason the lock screen showed (restart and 14 days are checked before the enrollment) |
| 42 | Touch ID | `--diagnose` is answered by `FXVaultMain` (the `@main` entry) before `FXVaultApp.main()`, so the app delegate never opens the database. The probe adds and deletes with `KeychainManager.addQuery` under its own service; it has no read path. Unsigned builds skip it |

### As built in v0.1.2 (build identities, the vault as source of truth)

| # | Area | Decision |
|---|---|---|
| 43 | Build identities | Debug is the separate app **FX Vault Dev**: `PRODUCT_BUNDLE_IDENTIFIER` `io.fractalx.fxvault.dev`, `CFBundleName` / `CFBundleDisplayName` from `FXVAULT_APP_NAME`, set per configuration in `project.yml`; Release stays `io.fractalx.fxvault` / "FX Vault" (`release-local.sh` gate). `InfoPlist.xcstrings` must not hold the two names (a localized value would override the build setting). The main window title is "FX Vault Dev" and the toolbar shows a DEV chip (`AppIdentity`). `Signed.xcconfig` keeps Debug ad-hoc (`[config=Debug]`), because the Developer ID profile is for the release App ID only; signing Debug needs its own App ID and profile |
| 44 | Build identities | Identifiers per use: the clipboard source marker follows `Bundle.main.bundleIdentifier`; constant in both builds are the logging subsystem (one `log stream` filter), the Touch ID keychain services (already split by vault flavor: `…dek` / `…dek.dev`), the keychain access group, the diagnose probe service, the `.fxvault` UTType and share schema (one file format), the caches and staging folder names. Both builds declare the same exported UTType; Debug ranks its document type `Alternate` (`FXVAULT_SHARE_HANDLER_RANK`), so Finder opens `.fxvault` files with the installed app |
| 45 | §7.1 | The vault is the source of truth: filling a secret that is on GitHub makes it a pending push (`force_push`, status Modified) unless "Already matches GitHub (don't push)" is checked (a checkbox, off by default). The drift review's "Accept GitHub" follow-up opens the fill with it checked (`ItemEditorContext.fillMatchesGitHub`); its "Fill Value…" for an unavailable Keep Local keeps the default. Share-import fills are unchanged (provenance unverified, no push request) |
| 46 | §7.1 | **Push on Next Sync** (table context menu, and a checkbox in the item editor applied on Save) sets `force_push` on a live synced secret with a value and nothing pending; the row shows "Will push" (`ConfigSyncStatus.willPush`), the pending count and the Sync button follow the observation stream, Revert clears it. Not offered for variables: their values are compared with GitHub's, so a difference is already a pending change or drift. A rename or kind change in the same save pushes anyway, so the request is skipped then |
| 47 | D27 | A push the user requested records when (`config_items.force_push_requested_at`, migration v8). D27 (preflight and the executor's per-scope re-check) and drift detection treat a GitHub change made clearly before that instant as covered: the push goes through and no drift is shown. A change after it, or within `SyncEngineConstants.requestedPushClockMargin` (5 s) of the request's whole second (GitHub lists whole seconds; clocks drift), still blocks (`.remoteChanged`, resolved in Drift review). An expired verification rebases the secret on its `pre_write_updated_at`, so the re-push keeps the request's effect. Revert keeps a value that already equals the synced one (it can lack a synced copy), so cancelling a push never erases a secret. Pushes FX Vault schedules itself (Keep Local, an expired verification) and share-import fills record no time and keep the strict rule. |

### As built in v0.2.0 (flexible sharing, connectivity banner, nearby chat)

| # | Area | Decision |
|---|---|---|
| 48 | Sharing | The scope values stay `secret` / `environment` / `repository`; any mix is `repository`. Schema v2 exists only for partial environments (`deploymentBranchPolicy: null`) and is written only when one is present (lowest-version rule), so whole environments, the whole repository and repository-level selections stay readable by 0.1.x (SHARING-PROTOCOL.md §1.1) |
| 49 | Sharing | A branch policy travels only with a fully checked environment. A partial environment never changes the receiver's policy; when it is missing on the receiver it is created with GitHub's policy and patterns if GitHub lists it (synced), else with all branches (pending create). `.item` on an environment item is now a partial environment (supersedes decision 34) |
| 50 | Connectivity | `ConnectivityMonitor` applies the first path at once and later changes after 2 s on the injected clock; Low Data Mode is online, requires-connection is offline. `GitHubReachability` makes no calls of its own: the sidebar, repository detail, Add by name, the Sync sheet (preflight, start, and the last change of a run that says anything about GitHub), Create Repository (owners and templates) and the drift review report their gh outcomes |
| 51 | Connectivity | Nearby share and Nearby Chat are never gated by `isOnline` (peer-to-peer Wi-Fi works with no internet route, and a Mac with Wi-Fi on but joined to no network reports no connection). Nearby Chat is disabled only by `hasNetworkInterface == false`. Clone is disabled offline too; the toolbar Import .env stays enabled (local only). A Sync sheet left open when the Mac goes offline cannot start a run or review deletions and says why in its footer |
| 52 | Nearby | Listener, browser and connection set `includePeerToPeer` (AWDL); the protocol bytes and KATs are unchanged. 0.1.x does not use AWDL, so 0.1.x and 0.2.0 Macs meet only on a shared network |
| 53 | Chat | Chat is domain-separated from share by its Bonjour type (`_fxvault-chat._tcp`) and label prefix (`fxvault/chat/v1`); the handshake moved, unchanged, into the internal `NearbyKeyExchange` used by both. Chat KATs are cross-checked with Python like the share KATs |
| 54 | Chat | Ephemeral by construction: the session keeps no history, the window's transcript lives in the view model only, and close, lock, sleep, screen lock, disconnect, timeout and End Chat wipe it. Idle 10 min, keepalive PING every 30 s (abort after 2 unanswered), no overall limit; the responder waits for a connection without a timer |
| 55 | Chat | Attaching asks ReauthGate before the picker opens and reuses `ShareAuthorizationPurpose.nearbySend` (its Touch ID prompt). The offer carries a manifest only; the value is decrypted when the peer asks and only if the item still has the offered name, kind and scope. "Save to my vault" goes through the share import preview and `SharingRepository.apply` |
| 56 | Chat | The chat window needs an unlocked vault; closing the main window locks the vault (D16) and so ends the chat. A responder whose unverified peer drops before HELLO, or leaves before the code is shown, re-advertises and returns to the people list without an "ended" screen or a failed-handshake count; only listener failures (no connection accepted) count, 3 in a row at most. `incomingConnection` clears the "visible" chip. There is no accept/decline step before the code comparison (open product question) |
| 57 | Nearby | Chat advertises the user's sanitized display name (Preferences › General › "Name for nearby Macs", else the macOS full name) as its Bonjour instance name. Nearby share and receive use the same name in HELLO (`ShareLocalIdentityModel.nearby(preferences:)`) but keep random Bonjour instance names |
| 58 | Chat | Flood limits: more than 100 TEXT/offer/request/decline/PING frames in 10 s, or more than 32 offers per chat, abort with `unexpectedMessage`; the window keeps 1,000 messages. Text and names drop every invisible character (`UnicodeScalarPolicy.isInvisible`); chat text keeps one blank line in a row and four combining marks per character. Messages are not selectable: Copy goes through `ClipboardManager`. Late async results (send, offer, request, a save preview) of a chat that ended are dropped. An offer's value provider refuses a value whose `value_fp` changed since the offer. Discovery uses the `local.` domain and filters this Mac by its registered name |
| 59 | Sharing | A missing partial environment whose items are all skipped is not created (`ShareEnvironmentPlanModel.createsEnvironment`); a nearby DECISION carries such an environment's id only with an accepted item. A tree opened for one item keeps sharing that item even if it is its environment's only item, until the checks change. Share import previews read GitHub only when online (`FeatureDependencies.checksGitHub`), and their "Import repository" button, the drift review's Refresh and resolutions, and Create Repository's Sync Now… are disabled offline with `ConnectivityCopy.offlineHelp`. The connectivity debounce is not restarted by more updates of the same transition; a reconnect cancels the previous one and re-lists drift only when the last check failed, never ran or was skipped offline |

### As built in v0.3.1 (gh login detection)

| # | Area | Decision |
|---|---|---|
| 60 | Logins | Root cause of "gh is logged in but FX Vault says Log in": Enterprise Managed User logins (`handle_shortcode`) failed `OwnerLoginValidator` and A3 dropped them silently. The one owner validator now accepts `_` anywhere but first (`^[A-Za-z0-9][A-Za-z0-9_-]{0,38}$`), because EMU users own personal repositories. GitHub counts the underscore and short code toward the same 39 characters, so `Limits.maxOwnerLoginLength` stays 39. Organization lists accept underscores too (GitHub never prints one). No schema change: no CHECK constrains login characters |
| 61 | Logins | A3 splits accounts into usable ones and `GHUnusableAccountModel`s (display login with token patterns redacted and invisible characters removed, the `NameRule`, active). Unusable accounts are never persisted; the setup screen (`GHStatusModel.unusableAccounts` when none is usable), Settings › Accounts and the diagnostics show them |
| 62 | Shell probe | The interactive login shell runs first (`-i -l -c`; csh `-i -c`), the login shell is the fallback on a timeout or missing markers, each 5 s. Interactive shells read `~/.zshrc` like Terminal; 0.3.0 missed PATH, `GH_CONFIG_DIR` and `XDG_CONFIG_HOME` set there. Every **Check Again** probes again (`refreshGHStatus(refreshingShell:)`); the launch probe is cached |
| 63 | Shell probe | The script adds one `/bin/sh -c '<report>'` (POSIX, so every shell can start it with what it exports): `FXV_GH=` + `command -v gh`, then `FXV_SET=<NAME>` for each of `GH_TOKEN`, `GITHUB_TOKEN`, `GH_CONFIG_DIR`, `XDG_CONFIG_HOME`, `GH_HOST` that is set and non-empty, tested with sh's `[` builtin. No value reaches stdout, an argv or a file; the parser keeps only an absolute `…/gh` path and exact names as enum cases. Real zsh, bash, sh and tcsh are tested with a synthetic token that must never appear in stdout |
| 64 | Locator | Candidates: override (alone), the shell's gh, Homebrew, shell PATH, MacPorts/Nix/`~/.local`. The first candidate that exists decides: used when trusted and new enough, otherwise detection fails with its reason. FX Vault never falls back to a gh behind it (0.3.0 skipped a rejected Homebrew gh and could run an older `/usr/local/bin/gh`). Only the decisive gh's `--version` runs (diagnostics run every trusted one); an untrusted binary never runs |
| 65 | Locator | Consented trust: when the only problem is that one other non-root user owns the file or its folders (never writable by others, never several owners), the setup screen names the owner and offers **Trust This gh**. `PreferencesManager.trustedGHBinary` stores `{path, owner uid}` (candidate path, so `brew upgrade gh` keeps it); `GHLocator` accepts exactly that path while every foreign owner is that uid. Settings › Advanced lists it with Revoke. The trust check reads the file system through `GHFileInspecting` so tests can model other owners |
| 66 | Accounts | No stored account and an exported `GH_TOKEN` / `GITHUB_TOKEN` is `GHStatusModel.environmentToken`: the setup screen explains it and offers `env -u GH_TOKEN -u GITHUB_TOKEN gh auth login` (BSD `env -u`, tested on macOS). Settings › Accounts shows a note while a token variable is exported. Unusable accounts take precedence over the token note |
| 67 | Diagnostics | **Copy Diagnostics** (setup screen) and the `gh` section of `--diagnose` render one `GHDiagnosticsModel`: candidates (path, source, resolved path, version, accepted / rejected / notFound, reason, owner uid and name, consent, chosen), shell path and probe mode, variable names, override and trusted gh, accounts (login, state code, token source only when one of gh's known names, scopes, missing scopes), unusable accounts, A3 error code. `--diagnose` collects it before the app starts (a detached task the entry point waits for; no database, no token fetch). The copied text is fixed English, like the JSON keys: a support artifact, not interface text |
| 68 | Status | `GHStatusModel` gains `.foreignOwner(path:owner:isHomebrew:)`, `.environmentToken(version:path:variables:)`, `.unusableAccounts(version:path:accounts:)`; `.outdated` carries the checked path and `.untrusted` the rejection, so the texts say what is wrong |
| 69 | Layout | Every column of the main split view takes the window's height (`mainColumnHeight()`: `frame(minHeight: 0, maxHeight: .infinity)`). AppKit sizes the split view from each column's minimum height, which SwiftUI measures at zero width; a wrapped empty-state message measured about 1,000 pt, so the split view outgrew the window and was centered (sidebar under the title bar, footer below the window). The detail fits its narrowest column with `ViewThatFits` rows (header actions, tags, kind pill and add actions); the table scrolls sideways. `MainWindowLayoutTests` |
| 70 | Accounts | FX Vault lists only gh's accounts, so an SSH alias whose key belongs to an account not logged in to gh had no place in Settings › Accounts. GitHub aliases that no account uses are listed with the `gh auth login` command and Check Again; mapping stays manual (no automatic `ssh -T` suggestions, v1.1 stretch) |
### As built in v0.4.0 (several rows at once, copy between scopes, repositories in chat)

| # | Area | Decision |
|---|---|---|
| 71 | Selection | Actions on several secrets or variables (v0.4.0) reuse the one-item rules: Delete stages GitHub deletions that Sync's §7.5 review confirms (Bryan, Q1: no immediate GitHub delete), Revert and Push on Next Sync apply only to the rows they fit, and a read-only scope offers nothing. One `ItemEditBatch` transaction per action, so a failure writes nothing |
| 72 | Copy | Copy and paste between scopes stays inside one repository (Bryan, Q2; other repositories get configuration through Share or chat) and inside the vault: the pasteboard gets names only (Transient, not concealed) and FX Vault recognizes its own copy by `changeCount`, never by reading it. Secrets without a value are not copied (a value-missing copy would only add a blocked row to fill by hand), unlike Duplicate environment, which keeps them by name |
| 73 | Chat | Chat version 2: chat offers `maxVer` 2 in HELLO (`NearbyChatProtocol.maxVersion`; nearby share keeps 1) and both sides use `min(maxVerI, maxVerR)`, which the transcript binds. Labels, TXT `v=1`, frame layout and frame types are unchanged, so a chat with 0.2.x or 0.3.x negotiates 1 and behaves as before. Configuration attachments (scope `repository` or `environment`) exist only at version 2: the sender refuses with `ChatError.peerNeedsUpdate` before an authorization is used, and the picker's Whole Repository tab says the other Mac needs 0.4 |
| 74 | Chat | A repository offer is a manifest (names and counts, `ChatConfigurationSummaryModel`). On request the provider rebuilds the package, gives it the offer's random entry ids (`ShareRepositoryModel.withEntryIDs(of:)`) and sends it only when every item's stored `value_fp`, the shape (names, kinds, scopes, policies) and the value states equal what the user authorized; otherwise the offer is withdrawn. Values read for a refused payload are wiped at once. A configuration payload may be as large as a nearby share (16 MiB); one item keeps 512 KiB |
| 75 | Chat | **Import Into…** (Bryan, Q3) plans the package as if it were for the repository the receiver picks: owner, name and GitHub id come from that vault row, then the same `ShareImportPlanner`, preview and `SharingRepository.apply` as any import, so environments it lacks are created and everything is pending for the next Sync. Repositories the account cannot change are listed with the reason (archived; admin required when the package has environments, which need admin) and cannot be chosen; the sender's `owner/name` is preselected when the vault has it. Cancel at the repository choice keeps the received values (nothing was planned); Cancel after the preview wipes them, as for one item |
| 76 | Chat | **Save as File…** (Bryan, Q3) reuses `ShareExportViewModel` with a chat source: `.fileExport` re-authentication, a fresh passphrase shown once, Save… or AirDrop. The file keeps the sender's name and package id; the package stays in the conversation, so it can still be imported. No plaintext `.env` from chat. The chat window shows one sheet at a time: a value that arrives while another sheet is open waits on its card |

### As built in v0.4.1 (copy across repositories, linked copies)

v0.4.1 and v0.5.0 are plan steps (tasks/todo.md); neither was released on its own. Both shipped
with v0.6.0 in release 0.6.0.

| # | Area | Decision |
|---|---|---|
| 77 | Copy | Copy and paste reaches every repository of the vault, whatever account it belongs to (Bryan, 2026-10-15, reversing decision 72's same-repository rule). The target must be editable by its own repository's account; the copy is one transaction on the target repository (`ItemEditBatch` over the target, sources read by id). The copied items moved from the detail view model, which is rebuilt for each repository, into `ClipboardManager` |
| 78 | Links | Every copy is linked to its source (`config_items.link_id`); a kept conflict is not. The link is local metadata: it never travels in shares, chat or `.env` files and does not change how a row syncs. Duplicate environment does not link (its copies are a starting point that is expected to diverge) |
| 79 | Links | Same value / Differs is computed when the popover or the editor needs it (values decrypted in memory, compared in constant time, wiped), not stored: a stored group fingerprint would have to be kept current by every value write path, and the sync diff (D11) never needs it. The table shows only the count, which needs no keys |
| 80 | Links | Update everywhere lives in the item editor: when a linked item gets a new value, its other places are listed, the ones that still have the current value checked and the ones the account cannot change disabled with the reason; Save updates the checked ones in one more transaction after the item's own edit (`updateLinkedCopies`). Each copy is an ordinary pending change for the next Sync |

### As built in v0.5.0 (teammates nearby, ping)

| # | Area | Decision |
|---|---|---|
| 81 | Teammates | A device identity per vault (Ed25519, X25519, announce key), created on first use and sealed in the vault as a secret field (`SecretFieldAAD`, `K_field`), not in the keychain: ad-hoc builds work and nothing is usable while locked. DEK rotation re-seals it |
| 82 | Pairing | Add Teammate reuses the nearby commit-reveal handshake (`NearbyKeyExchange`) with its own purpose and labels (`.pair`, `fxvault/pair/v1`), then exchanges cards signed over the transcript hash and the role. The encrypted channel was extracted from `NearbyKeyExchange` into `NearbyChannel`, which the paired handshake reuses |
| 83 | Presence | One service, `_fxvault-team._tcp`, advertised under a pseudonym from the announce key and the 15-minute window; one announce key per device, shared with every teammate at pairing, so one advertisement serves all of them. Removing a teammate renews it; the others get it through an authenticated CARD_UPDATE the next time they are seen (`needs_card_update`) |
| 84 | Sessions | Every connection to the presence service starts with a plaintext routing preamble (team or chat); the purpose-bound handshakes make a false preamble fail. The paired handshake is SIGMA-style with signatures over the transcript hash naming both devices; the responder proves itself only to a verified teammate |
| 85 | Chat | Chat version 3 adds TEAMMATE_IDENT: a teammate opened from a bubble skips the code by signing the chat transcript; strangers and older peers compare the code as before. A chat from a bubble reaches the teammate through its presence (preamble `chat`), so it works without their chat window open; the window shows "Teammate" and waits up to 3 s for the proof before showing the code |
| 86 | Visibility | Who can see me: Nobody / Teammates (default) / Everyone nearby. Everyone nearby also advertises the display name on the chat service while the chat window does not (it yields to the window); an incoming chat opens Nearby Chat as the responder. Only teammates can be pinged |
| 87 | Pings | A sound when FX Vault is frontmost, otherwise a notification with the sound (Focus applies); the Dock icon bounces once. Limits: 1 per teammate every 10 s (sender), 5 per teammate per minute (receiver). Mute per teammate and Mute all still bounce the bubble |
| 88 | Energy | Advertising and listening while unlocked; browsing only while the main window is visible and FX Vault is active; a person stays 30 s after the last sighting; `last_seen_at` written at most once a minute |

App side (v0.5.0): `TeamPresenceManager` (`App/Managers`, owned by `AppViewModel`, a lock
observer) runs presence: the listener, the browsers (`TeamPresenceNetworking`: live
`NWTeamListener`/`NWNearbyBrowser`/`NWNearbyTransport`, inert in previews, a fake network in
tests), incoming routing, pings (`PingAlerting`: `SystemPingAlerts`), card updates and the
`people` the toolbar's `NearbyPresenceView` draws. A chat it starts goes to
`AppViewModel.startChat(_:)`, a one-slot mailbox (`takePendingChatStart()`, `chatStartRequests`)
that the Nearby Chat window reads (`NearbyChatViewModel.startPendingChat()`); the main window
registers the window opener (`setChatWindowOpener`). Preferences › Teammates is
`TeammatesSettingsScreen`/`ViewModel`; Add Teammate is `AddTeammateSheet`/`ViewModel` (the
presenter starts and closes the view model). Visibility and Mute all live in
`PreferencesManager` (`nearbyVisibility`, `mutesAllPings`).

### As built in v0.6.0 (shared spaces between teammates, experimental)

| # | Area | Decision |
|---|---|---|
| 89 | Placement | The space core (log rules, versions, keys, marker, gate) lives in SharingKit `Space/`, not in a new SpaceKit target as S10 proposed: it needs the teammate device keys, cards and sessions SharingKit already owns. SyncEngine sees only `SyncSpaceCoordinating` (marker texts and `SpaceGateDecision`, which moved to VaultCore), so it stays independent of SharingKit |
| 90 | Versions | Every version is a full snapshot of the scope as GitHub holds it (S3): last pushed values and GitHub's `updatedAt` of every row with a synced name; an unverified push keeps the previous version's entry. A version is recorded only after a verified push, a share (genesis) or a member change, and only when the items changed. Receivers apply only the newest content version |
| 91 | Marker | `FXVAULT_SPACE` is a reserved name (`NameRule.reservedName`), split off every variable listing, written only by `setSpaceMarker`. Its writes are not journaled: `spaces.claimed_version` stays set from the claim until the `published` marker is confirmed by a re-read, and `SpaceClaimReconciler` finishes or drops it at unlock |
| 92 | Gate | Strict (Q1): behind, another member's live claim, forked, an invalid marker or not being a member block every item change of the scope; other scopes still sync. A claim older than 15 minutes is offered as Take Over… with a confirmation and recorded in the next version's note (Q3). Renaming or deleting a shared environment is blocked |
| 93 | Receive | A space this Mac lacks arrives as its whole log (verified from genesis, this device a member at the head), so a member added later bootstraps; a known space accepts versions that follow its head, in order; nothing advances while this Mac holds a claim in it. Local drafts stay on top (Keep Mine) and are reported; History › Restore takes a teammate's value |
| 94 | Sessions | A spaces service (preamble `0x03`) over the paired handshake, pull-only: heads, then one version per fetch in chunks. A responder that sees the peer ahead pulls back in its own session. Sync runs when a sharing teammate is seen, every 2 minutes while FX Vault is active, after a publish (members are told), and on Get Updates from Teammates |
| 95 | Remote (Q4) | Off by default; per teammate on both Macs; spaces service only; an un-advertised TCP listener on a chosen port answering only allowed teammates; 5 failed sessions in 10 minutes close it for 10 minutes; outgoing only to the typed address with the teammate's key proven. In the background only remote teammates are synced |
| 96 | Members | Adding wraps every epoch key so far for the new member (Q2); removing starts a new epoch and returns the secrets to rotate. Both write the marker like a push (claim, version, publish) |
| 97 | Drift | A finding in a shared scope whose marker is ahead is a teammate's change (S9): Keep Local and Accept GitHub are not offered; Get Updates from Teammates is. Once the version arrives, its snapshot explains GitHub's change and the finding disappears |
| 98 | History | Item versions show a 4-byte fingerprint every member computes the same way (epoch-1 key); revealing an older value asks for Touch ID or the master password (`ReauthPurpose.spaceHistory`) and re-masks after 30 s |

App side (v0.6.0): `SpaceSyncManager` (`App/Managers`, owned by `AppViewModel`, a lock observer,
started with presence) pulls and answers spaces sessions through `TeamPresenceManager`
(`spacesTransport(to:)`, `spacesConnectionHandler`, `teammateSeenHandler`) and, for remote
teammates, `SpaceRemoteNetworking` (live `NWSpaceListener`/`NWNearbyTransport`, inert in
previews, recorded in tests); `SpaceExchangeAdapter` implements `TeamSpaceExchanging` over
`SpaceRepository`. Screens: `Spaces/ShareSpaceScreen` (scope menu › Share with Teammates…),
`Spaces/SpaceScreen` (History, Members; opened from the scope menu or the detail header's
"Shared · vN" chip); the Sync sheet groups a blocked shared scope into one issue with Get Updates
from Teammates or Take Over…, and asks "What changed?"; drift review shows teammates' changes;
Preferences › Teammates › Outside this network holds the port and each teammate's switch and
address (`remoteSpacePort`).

## App shell

App target `FXVault`, `MainActor` by default; everything is internal (`@testable import` in
AppTests).

**Composition and state** (`App/`, `App/Composition/`).
- `AppContainer` (`Mode` `.live` / `.preview` / `.test`; `.preview` while hosting tests, so the
  test host never touches `~/Library`, the keychain or gh). Properties: `vaultManager`, `data:
  VaultDataComponents`, `reauth: ReauthGate`, `preferences`, `clipboard`, `autoLock`,
  `ghStatusProbe`, `dockBadge`, `passphraseGenerator`, `vaultDirectory`, `clock`,
  `connectivity`, `gitHubReachability`, `hasSideEffects`. `live()` uses
  `GitHubEnvironmentStatusProbe` and `NWPathMonitorSource`; `preview()` a `FixedGHStatusProbe`
  and a `FixedNetworkPathSource` (always online; tests pass their own monitor).
- `AppBootstrap` (`.ready(AppViewModel)` / `.failed(ErrorPresentationModel)`), owned by
  `AppDelegate`: a startup-failure screen, never a fallback to an empty vault.
- `@Observable AppViewModel`: `phase: VaultPhase`, `ghStatus` / `isCheckingGH` /
  `refreshGHStatus()` (the last status stays while re-checking), `showsGHSetup` /
  `deferGHSetup()`, `pendingChangeCount` and `pendingCounts` (observed from
  `ConfigRepository.observePendingCounts()`; also the Dock badge), `isSyncing` /
  `beginSyncActivity() -> SyncActivity`, `pendingImports` / `openShareFiles(_:)` /
  `takeNextPendingImport()`, `setMainWindowOpener(_:)` / `requestMainWindow()`,
  `lastReconciliation` (launch reconciliation after each unlock, after the gh probe),
  `lock(trigger:)`, `didUnlock()`, `completeOnboarding()`, `didResetVault()`,
  `applicationWillTerminate()`, `shouldOfferTouchID(afterInvalidation:)` /
  `recordTouchIDOfferAnswer()` (the one-time Touch ID offer) and `make…ViewModel()` factories.
- Scenes: the main `Window` (`SceneID.main`), Settings, and since v0.2.0 the **Nearby Chat**
  `Window` (`SceneID.nearbyChat` = `"nearby-chat"`, `NearbyChatScreen(app:)`), opened from
  Share › Nearby Chat… (toolbar and Vault menu) and listed by SwiftUI in the Window menu; never
  restored at launch (`isRestorable = false`).
- `FXVaultMain` (`FXVaultApp.swift`) is the `@main` entry: `DiagnoseCommand.runIfRequested()`
  answers `--diagnose` (JSON on stdout, then `exit(0)`) before `FXVaultApp.main()` creates the app
  delegate, so no window, vault or database opens. `App/Diagnostics`: `DiagnosticReporter`
  (`makeReport(infoDictionary:capabilities:probe:gh:)`, pure; `versionAndBuild`),
  `DiagnosticReportModel` (explicit `null`s, sorted keys; `gh` section since v0.3.1, collected by
  `DiagnoseCommand.collectGHDiagnostics` with the real shell and gh) and
  `GHDiagnosticsTextRenderer` (the Copy Diagnostics text).
- `SyncActivity`: holds the auto-lock `SyncActivityAssertion` and drives the Sync button's
  progress. `end()` is idempotent; a lock ends every activity.
- `protocol LockObserving: AnyObject { func vaultDidLock() }` (held weakly; register with
  `app.addLockObserver(_:)`).
- `.fxvault` files: `AppDelegate.application(_:open:)` and `RootScreen.onOpenURL` call
  `openShareFiles` (only `.fxvault` file URLs, each once), which brings the main window back
  (`NSApp.activate()` plus the `openWindow` action `RootScreen` registered). The vault unlocks
  first; `MainViewModel.presentNextPendingImport()` then opens `.shareImport` for the oldest file,
  and the next one when that sheet closes.

**Managers** (`App/Managers`).
- `AutoLockManager(clock:idleSource:signalSource:ticker:timeout:)`: `start(onLock:)`, `stop()`,
  `recordInteraction()`, `checkInactivity()`, `beginSyncActivity() -> SyncActivityAssertion`,
  `observeClose(of:)`. `LockTrigger` lists every trigger (§5.7). Sources are protocols
  (`IdleEventSource`, `LockSignalSource`, `InactivityTicker`) with live implementations
  (`LocalEventIdleSource`, `SystemLockSignalSource`, `DispatchInactivityTicker`) and
  `InertLockSources`.
- `ClipboardManager(pasteboard:clock:clearDelay:)`: `copy(_:)` (values: §5.9 markers, cleared
  after 30 s if still owned), `copyCommand(_:)` (plain text such as `brew install gh`, never
  cleared), `clearIfOwned()`; never reads the pasteboard.
- `@Observable PreferencesManager(store:)`: `autoLockMinutes` / `autoLockTimeout`, clone folder,
  `ghPathOverride`, `trustedGHBinary` / `trustGHBinary(_:)` / `revokeTrustedGHBinary()` (v0.3.1,
  `preferences.trustedGHPath` and `preferences.trustedGHOwnerUID`, validated on read),
  `isRecoveryKeyConfirmationPending`, `hasAnsweredTouchIDOffer`,
  `nearbyDisplayName` / `nearbyName` (v0.2.0: the name nearby Macs see, Preferences › General;
  nil uses the macOS full name); `UserDefaultsPreferencesStore` (live) or
  `InMemoryPreferencesStore`.
- `DockBadgeDisplaying` (`DockBadgeManager`, `RecordedDockBadge`).
- `ConnectivityMonitor(source:clock:debounce:)` (v0.2.0, `@Observable`): `isOnline`,
  `isConstrained`, `start()` (by `AppViewModel.init`), `stop()` (at quit),
  `addObserver(_ ConnectivityObserving)` (held weakly). The first path applies at once; later
  changes apply only after holding `Theme.Durations.connectivityDebounce` (2 s) on the injected
  clock, so a flapping path never reaches the UI. Satisfied (also constrained, Low Data Mode) is
  online; unsatisfied and requires-connection are offline. Sources: `protocol NetworkPathSource`
  with `NWPathMonitorSource` (live; reads path metadata only, sends nothing) and
  `FixedNetworkPathSource`; `NetworkPathModel` is the reduced `NWPath`. Separately,
  `hasNetworkInterface` (v0.2.0 Nearby Chat; applied at once, no debounce) is true while any
  interface can reach a nearby Mac: the path lists one other than loopback, or the Wi-Fi radio is
  on even when it joined no network (`WiFiRadio`, CoreWLAN power state only; a power change
  re-reports the path). Nearby Chat is disabled only when it is false; `isOnline` never gates it.
- `GitHubReachability` (v0.2.0, `@Observable`): `isResponding`, `isRetrying`,
  `record(error)`, `recordSuccess()`, `reset()`, `retry(_:)`. It makes no calls of its own: view
  models report the outcome of the gh calls they already make. `GHError.network` / `.timeout`
  (after the scheduler's retries) mean not responding; a success or an error GitHub returned
  (404, 422, 401, rate limit, 5xx, SAML) means responding; local failures say nothing.
  `Error.gitHubFailure` unwraps the `GHError` inside VaultData and SyncEngine errors. Retry runs
  the main window's own calls again and clears the state when none of them reported anything.
- `GHStatusProbing.probe(refreshingShell:)`: `GitHubEnvironmentStatusProbe(github:preferences:)`
  (`detectGH` with the override and trusted gh, then `accounts()`; maps the locator report) and
  `FixedGHStatusProbe`. `GHStatusModel`: `.checking`, `.unknown`, `.ready(version:path:)`,
  `.notInstalled`, `.outdated(found:required:path:)`, `.untrusted(path:reason:)`,
  `.foreignOwner(path:owner:isHomebrew:)`, `.noAccounts(version:path:)`,
  `.environmentToken(version:path:variables:)`, `.unusableAccounts(version:path:accounts:)`,
  `.failed`; `needsSetup`, `isReady`. `AppViewModel.refreshGHStatus(refreshingShell:)`,
  `trustGHBinary(_:)`, `revokeTrustedGHBinary()`.

**Screens** (`App/Screens`, each `[Name]Screen` + `@Observable [Name]ViewModel`).
- `Onboarding`, `Lock` / `RecoveryReset` (both with `GHStatusRow`). The lock screen shows
  "Unlock with Touch ID" (SF Symbol `touchid`) when Touch ID can run, and otherwise names why the
  password is required under the password field (`LockNoticeModel`: "Password required: After a
  restart" / "Every 14 days" / "Fingerprints changed"). After a password unlock the vault is
  unlocked at once; when `AppViewModel.shouldOfferTouchID` allows it, `TouchIDOfferScreen`
  (a sheet over the lock screen, `TouchIDOfferViewModel`) is answered before the main window
  appears: Turn On Touch ID (`enableBiometrics` with the password just typed) or Not Now
  (remembered in `PreferencesManager.hasAnsweredTouchIDOffer`). A lock discards it unanswered.
- `GHSetup` (§10.3): after unlock while `ghStatus.needsSetup`; kinds install / upgrade (found
  version, the checked path, and why 2.97 is required) / untrusted (reason-specific text) /
  trustOwner (v0.3.1: the owner, the risk, **Trust This gh** as an outline button, never the
  default) / login / environmentToken (v0.3.1: `env -u GH_TOKEN -u GITHUB_TOKEN gh auth login`) /
  unusableAccounts (v0.3.1: each login with its reason) / failed; copyable `brew install gh`,
  `brew upgrade gh`, `gh auth login`; **Copy Diagnostics** (ghost, footer leading; plain-text
  copy); **Check Again** (probes the shell again); **Not Now** (work without gh until the next
  launch or until gh is ready).
- `Preferences`: General, Security, **Accounts** (`AccountsSettingsViewModel`: gh path and
  version, per account token state, scopes with copyable fix commands, SSH alias picker from
  `~/.ssh/config`, **Test** "Authenticates as <login>", **Re-check**; v0.3.1: a note with the
  `env -u` command while the shell exports a token variable, and "Accounts FX Vault can't use";
  v0.3.2: "SSH aliases without an account" lists the GitHub aliases no account uses, with the
  `gh auth login` command and **Check Again**, which reloads the tab and, through
  `AppViewModel.accountsDidChange()` / `accountsRevision`, the main window's sidebar; the aliases
  load before gh detection, so they show while gh is missing),
  Advanced (v0.3.1: the trusted gh with its owner and **Revoke**).
- `Main` (§10.4), `MainViewModel` owns:
  - `SidebarViewModel` (`Main/Sidebar`): vault repositories observed (work without gh), gh
    accounts and catalogs loaded when gh is ready; `SidebarGrouping.sections(_:query:)` (pure)
    groups account → owner (Personal, organizations in gh's order, others by name) → repositories,
    with badges (private, archived, fork, unavailable, not on GitHub), scope warnings, SAML and
    truncation notes and search (the toolbar search field); Import, Clone, Share…, Remove from
    vault (confirmed); Add repository by name (`Main/AddRepository`). v0.3.0 draws the sidebar
    and scope rows itself (`.fxRowBackground`, docs/DESIGN.md) instead of a native `List`
    selection; `MainColumnSelection` (pure) keeps Up/Down keyboard selection and owner groups
    collapse from their mono label.
  - `ScopeListViewModel` (`Main/ScopeList`): "Repository" plus environments
    (`observeScopes`), pending dot, value-missing count, context menu Settings / Rename /
    Duplicate / Export .env / Share / Revert / Delete (confirmed), "+ New Environment" (admin).
  - `RepoDetailViewModel` (`Main/RepoDetail`): header (owner/name, visibility, capability chip,
    Clone, Refresh, drift banner, deployment branches with Edit, plan note on private
    repositories, read-only explanation) and `ConfigTableView` (Secrets | Variables over one
    `Table`; masked secrets with the eye toggle, "Value missing", plaintext variables; Reveal,
    Copy, Edit / Fill Value, Convert or Move, Push on Next Sync (secrets), Revert, Delete). Next
    to the Secrets | Variables `SegmentedPill`, Add Secret / Add Variable (primary pill) adds one
    item of the tab's kind, with Paste Multiple… (outline pill) and Import .env File… (outline
    circle) beside it; ⌘V in the detail
    column (`onPasteCommand(of: [.plainText], validator: validatePaste)`, `handlePaste(_:)`
    reads the providers) opens the import preview prefilled. All three pass the tab's kind as `defaultKind` and the open scope as the
    target. Revealed values re-mask after
    `Timeouts.revealRemask` (injected clock), on resign active, on scope change and on lock.
    The drift check runs when a repository opens (`DriftRepository.detectOnOpen`).
    v0.4.0 multi-selection: ⌘/⇧-click and ⌘A select rows (`selection`); with two or more
    selected, `RepoDetailSelectionActions` replaces the add actions ("N selected", Push on Next
    Sync and Revert when some rows allow them, Delete…, Deselect) and the context menu offers the
    same (`ConfigSelectionMenu`); ⌫ is `deleteSelection()`. `ConfigSelectionActionsModel` keeps
    the rows each action applies to; `ConfigDeletionModel` holds one or several rows for one
    confirmation (synced rows are deleted on GitHub by the next Sync after its review, rows never
    synced are removed at once). Each action is one transaction:
    `ConfigRepository.deleteItems(_:repositoryID:)`, `revertItems(_:repositoryID:)`,
    `requestPush(_:repositoryID:)`, all or nothing.
    v0.4.0 copy and paste between scopes of the repository: ⌘C (`onCommand(copy:)` on the table,
    `copySelection()`) keeps `CopiedItemsModel` (ids, names, source scope) and writes only the
    names through `ClipboardManager.copyItemNames(_:)`; ⌘V (`handlePaste`) copies those items
    into the open scope while `ClipboardManager.holdsItemNames` (by `changeCount`), otherwise it
    opens the `.env` import as before. Copy To › (row and selection menus, the selection bar)
    lists `copyTargets` (the other scopes, disabled where the account may not add items).
    `ConfigRepository.copyConflicts(_:to:repositoryID:)` finds the names the target has; then
    `ItemCopyRequestModel` asks Replace (values) / Keep Existing / Cancel, and
    `copyItems(_:to:repositoryID:conflicts:)` adds the rest as pending adds in one
    `ItemEditBatch` (a tombstone of the name comes back). Secrets without a value are left out
    and named in the notice.
    v0.4.1 any repository and linked copies: the copied items (`CopiedItemsModel`: ids, names,
    source repository and scope) live in `ClipboardManager` (`copyItems(_:)`, `itemsToPaste`,
    `forgetCopiedItems()` on lock and quit), so ⌘V pastes into any repository's detail. Copy To
    ends with "Another Repository…", which presents `MainSheet.copyToRepository`
    (`CopyToRepositoryScreen`/`ViewModel`: the vault's repositories by account, searchable, the
    chosen repository's scopes with the read-only reason, the same Replace / Keep question, then
    the outcome with Show). A linked row shows `LinkedChip` (link symbol and count) next to its
    name; the chip and the row menu's Show Linked Copies open `LinkedCopiesPopover`
    (`RepoDetailViewModel.linkedPopoverRowID` / `linkedCopies`): each place with its comparison,
    a click opens it (`MainActions.open(_:_:)` selects the repository, then the scope through
    `ScopeListViewModel.select(scope:)`), and Unlink.
    v0.4.0 header actions menu: an `ellipsis` outline circle after Clone and Refresh
    (`ScopeActionsMenu`) shows the scope list's `ScopeContextMenu` for the selected scope
    (Settings, Rename, Duplicate, Export .env, Share, Revert Changes, Delete… for an environment;
    Export .env and Share for the repository level), so creating and deleting environments is
    not only a right-click away; the delete confirmation stays on the scope list.
  - Connectivity (v0.2.0): `ConnectivityBannerView` (a `Banner`, at the top of the detail
    column since v0.3.0) shows
    `MainViewModel.connectivityBanner` ("No internet connection. Your changes stay in the vault;
    sync when you're back online.", or "GitHub isn't responding. Try again in a moment." with
    Retry → `retryGitHub()`; offline wins). While offline, Sync, New Repository, Import (sidebar
    and detail prompt), Add repository by name, Clone, Refresh, the catalog reload and every
    drift check are disabled, with `ConnectivityCopy.offlineHelp` as their `.help`
    (`networkHelp(_:)`), and the router refuses `MainSheet.needsInternet` routes (`.sync`,
    `.createRepository`, `.addRepositoryByName`, also when chained by a feature). Local editing,
    `.env` import/export, file sharing and nearby send/receive stay available: nearby is
    peer-to-peer (AWDL) and needs no internet route. `MainViewModel` is a `ConnectivityObserving`:
    when the connection returns it resets `GitHubReachability`, reloads the repository lists if
    they never loaded or failed (`SidebarViewModel.needsReload`) and re-runs the open
    repository's drift check (`reconnectTask`). Sidebar, repository detail, Add by name, the
    Sync sheet, Create Repository and the drift review report their gh outcomes to
    `GitHubReachability` (decision 50).
  - Toolbar: the FractalX mark, the window title and the selected `owner / repo` in mono (the
    system title is removed on macOS 15+; macOS 14 keeps it and omits the duplicate name), a DEV
    chip in Debug builds (decision 43), New Repository, Import .env, Share menu
    (File… / Nearby… / Receive Nearby… / Nearby Chat…, which opens the chat window), Lock,
    Sync (`SyncToolbarButton`, count in the label, disabled at 0, while locked, while syncing and
    without gh). Menu commands (`VaultCommands`): File › New Repository… (⌘N), Import .env… (⇧⌘I);
    Vault › Lock (⌃⌘L), Sync (⇧⌘S), Share. Commands reach the window through
    `FocusedValues.mainViewModel`.
- Feature sheets (all presented by the router below; each `XScreen` + `@Observable XViewModel`):
  - `ItemEditor` (§7.1, M3): `ItemEditorViewModel` (`LockObserving`) adds, edits, fills and
    converts or moves one item through `ConfigRepository`. Kind is locked once on GitHub; names
    are uppercased (ASCII only) and checked live with `GitHubNameValidator` plus a fold-key
    duplicate check; values only through `SecretValueEditor` (trailing-newline notice, size and
    empty checks). Editing a secret starts empty ("Edit Current Value" decrypts on request).
    Credential-looking variables (`CredentialClassifier`) get "Make It a Secret" / "Convert to
    Secret…". Fill pushes on the next Sync unless "Already matches GitHub (don't push)" is
    checked; editing a synced secret offers "Push on Next Sync" (decisions 45–46). Secret →
    variable asks first (Cancel is the default). The typed value is wiped after save, on close
    and on lock.
  - `Environment` (§7.6, M4–M5): New / Settings / Rename / Duplicate, over
    `EnvironmentDirectoryModel` (fold-key name status: taken, reserved by a pending change,
    restores a deleted one). Settings edits the policy with `BranchPolicyEditorView` and shows
    GitHub's extra protection rules and the plan note. Rename predicts local / letter-case-only /
    recreate on GitHub and is blocked while a secret has no value ("Enter Values…" opens the fill
    editor). Duplicate shows counts only.
  - `Sync` (§7.2–§7.5): `SyncViewModel` over the `SyncServicing` seam (`LiveSyncService(sync:
    github:cloner:)`): Summary (scope lines with names only, blocked changes with fixes, drift
    routed to review, "FX Vault write limit this hour: X of 450", credential confirmation) →
    Deletions (live fetch, "will be lost" marks, foreign rules, "I understand this cannot be
    undone", no default button) → Progress (holds a `SyncActivity`, Cancel after the call in
    flight, not dismissable, a lock cancels) → Result (Failed / Blocked / Skipped / Succeeded
    with fixes, stop reason, warnings, clones). Clone from the result asks for a folder through
    `ClonePanel.folder(preferences:)` when none is set. Afterwards it requests `.drift(id)` and,
    for a created repository, `.catalog`.
  - `Drift` (§7.7): `DriftReviewViewModel` over `DriftServicing` (`LiveDriftService`): findings
    in the plan's wording, Keep Local / Accept GitHub (no default), confirmation before removing
    local data, a secret's Accept GitHub chains to the item editor in fill mode, stale findings
    re-check. `DriftBannerView` ("N changes on GitHub") in the detail column.
  - `CreateRepo` (M4): `CreateRepoViewModel` (`LockObserving`) stages through
    `RepoCreationRepository.stage` (one transaction; nothing reaches GitHub before Sync). Owner
    picker from `creation.owners`, `RepoNameValidator` plus a 500 ms debounced availability
    check on the injected clock, templates, inline staged environments (shared
    `BranchPolicyEditorView`) and items (`SecretValueEditor`), "Clone to my Mac" (needs a clone
    folder; warns without an SSH alias). After Create it selects the repository in the sidebar
    (`actions.select`) and offers Sync Now… (`.sync([id])`).
  - `EnvFile` (§5.12, M5, v0.1.1): import (file or paste → table with key fix, kind, conflict
    Skip / Overwrite plus Overwrite All, and target scope, preselected to the open scope →
    `EnvFileRepository.applyImport`). Paste mode shows the editor (`EnvPasteEditorView`, the
    shared `SecretTextView`, focused for Paste Multiple…, with a SwiftUI `PasteButton`) above
    the preview, parsed live `Theme.Durations.envPasteParseDebounce` after the last edit (Import
    waits for it); issues with line numbers and an empty state; row edits survive re-parses.
    Kinds start as `defaultKind` (the detail tab) or, without one (toolbar Import .env),
    `CredentialClassifier`'s suggestion; a credential-looking variable shows a "Make Secret"
    warning badge; Mark All as Variable / Secret also applies to rows added later. Parsed
    values are wiped on every re-parse, Start Over, close and lock; the pasted text is cleared
    after the import, on switching to File, on close and on lock) and export (`ReauthGate` first →
    plaintext, skipped and unverified-share warnings → save panel → iCloud confirmation before
    any write → 0600 write → git tracked / not ignored / ignored / unknown, with the `.gitignore`
    offer). One authorization per write; a failed write uses it up.
  - `Sharing` (§9, M6): file export (`ReauthGate.authorizeShare(.fileExport)` → multi-select
    tri-state scope tree (`ShareScopeTreeModel`, also used by the nearby "what to send" picker)
    with per-scope counts (`ShareContentSummaryView`) → `exportFile` into `$TMPDIR/io.fractalx.fxvault.shares/<uuid>/` (0700 / 0600) →
    passphrase shown once → Save… (0600) or AirDrop…; the staged file is removed on close or when
    AirDrop ends), import (header before passphrase; one message for wrong passphrase / damaged
    file; chips, Keep mine default, widening-policy and replay confirmations; one-click import of
    a missing repository through `ShareRepositoryImporter`), and nearby send / receive
    (experimental; `NearbyNetworking` over `NWNearbyBrowser` / `NWNearbyTransport`;
    `SASCodeView` with no default button; re-authentication before the manifest; advertising
    only while the receive sheet is open; no automatic retry). Re-authentication sheets use
    `ShareReauthModel` / `ShareReauthView`.

- `NearbyChat` (v0.2.0, experimental; its own window, not a sheet): `NearbyChatViewModel`
  (`LockObserving`, built by `AppViewModel.makeNearbyChatViewModel()` over
  `nearbyChatDependencies()`, whose `present` brings the main window forward) with steps
  `locked` / `unavailable` / `browsing` / `connecting` / `comparing` / `chatting` / `ended`.
  While browsing, the window advertises under `ShareLocalIdentityModel.nearby(preferences:)` and
  lists peers (`NearbyChatNetworking`: `LiveNearbyDiscovery(purpose: .chat)` and
  `advertisingChat`, this Mac left out) with "You're visible to nearby Macs as …"; connecting or
  being connected stops both. `SASCodeView` (no default button), then bubbles with times, an
  attachment card per offer, and the composer (⌘↩, `Limits.chatMessageBytes` after
  sanitizing). "Attach secret or variable…" opens `ChatAttachmentPickerViewModel`
  (`ShareReauthModel(.nearbySend)` first, then one item from `chat.attachableItems()`); a
  received card offers "Save to my vault" (requests the value, then `ChatSaveViewModel`: the
  share import preview with `ShareImportPlanEditor`, repository import, `SharingRepository.apply`)
  or "Dismiss". Window close, lock (sleep and screen lock lock), "End Chat", the peer leaving, a
  disconnect or timeout end the chat: the transcript, cards, draft and any received value are
  wiped and the window shows "Conversation ended. Nothing was saved." Disabled only without any
  network interface (`ConnectivityMonitor.hasNetworkInterface`); closing the main window locks the
  vault (D16) and therefore ends the chat.
  v0.4.0: `peerAcceptsRepositories` (known once the codes match) enables the picker's Whole
  Repository tab (`ChatAttachmentPickerViewModel.Mode`, `ChatAttachmentChoiceModel`); with an
  older peer the tab explains the update instead. A received repository card offers Import
  Into…, Save as File… and Dismiss (`handleConfiguration(_:_:)` asks for the values first and
  runs the action when they arrive). Import Into… opens `ChatSaveViewModel` at `.choosingTarget`
  (`ChatImportTargetModel`: read-only reason per repository), then the same preview
  (`ChatSaveViewModel.Outcome`: `imported`, `wiped`, or `kept` when closed before Continue); Save as
  File… opens `ShareExportViewModel(chatAttachment:…)` (`fileSheet`; `makeFileDelivery` is
  injected for tests). A file saved and then a cancelled import leaves the card at "Saved as an
  encrypted file, not imported" (`hasSavedFile`).

**Components** (`App/Components`): `SecretValueEditor`, `MaskedValueCell` (display-only: masked /
revealed / plain / missing, the view model owns reveal state), `CommandRow`,
`RecoveryKeyGridView`, `PassphraseView`, `StatusChip`, `EmptyStateView`, `SyncToolbarButton`,
`GHStatusRow`, `PasswordStrengthMeter`, `NewPasswordFields`, `WindowAccessor`,
`View.screenCaptureProtected()`, `View.errorAlert(_:)` (`ErrorAlert`). Shared by the feature
sheets: `ConfigEditorSheet(eyebrow:title:subtitle:primaryTitle:isPrimaryEnabled:isWorking:width:
onCancel:onPrimary:content:)` (v0.3.0 board SyncReview: eyebrow, 28 pt title and muted subtitle,
labelled fields in a scroll view sized to its content, footer with the secondary Cancel = Esc and
the primary pill = Return) with `ConfigEditorNoteModel` / `ConfigEditorNoteView`, and the sheet
building blocks in the same file: `ConfigSheetFooter` (mono `.statusLine` meta or a notice, then
the pills), `ConfigSheetField` (`SectionLabel` above a field or block) and `ConfigSheetList` (rows
in a hairline `.container` card). The sheet header, confirmation checkbox row, callout, inline
error, brand link and sheet content chrome are design components shared by every sheet and form
(`App/Components/Design/SheetChrome.swift`: `SheetHeader`, `FXCheckboxRow`, `SheetCallout`,
`InlineErrorView`, `FXLinkButtonStyle`, `.fxSheetContent`; v0.3.0 integration merged the three
per-feature copies into them); the Sync, Drift review,
environment, item and New Repository sheets use them. `SecretValueEditor` is framed like a 12 pt
rounded input (brand ring while the text view is first responder). `BranchPolicyFormModel` (pure:
All / Protected branches only / Selected patterns, `BranchPatternValidator`, at most 50 rules,
`draft`, `isReadyToSave` waits for a typed but unadded rule) and
`BranchPolicyEditorView(form:isEnabled:)` (labelled blocks: radio group, rules in a hairline card,
add row; used by Environment Settings, New Environment and New Repository). Helpers:
`TaskBag` (cancels a view model's observation tasks when it goes away), `ExternalLinks`
(`environmentPlans`, `samlSingleSignOn`).

**Errors** (`App/Helpers/Extensions`): `ErrorPresentationModel`, `Error.presentation`,
`Error.isCancellation`; localized `VaultError`, `ValidationError`, `PasswordPolicyError`,
`GHError` (keys `error.gh.*`), `GitError`, `GitHubEnvironmentError`, `RepoCatalogError`,
`ConfigRepositoryError`, `RepoCreationError`, `SyncRepositoryError`, `DriftRepositoryError`.
Feature-owned and feature-only errors conform to `PresentableError` (`errorPresentation`) in the
feature's folder: `EnvFileError` (`EnvFile/EnvFileError+Extension.swift`), `SharingError`
(`Sharing/SharingError+Extension.swift`, one "Wrong passphrase or damaged file" message for a
wrong passphrase, a damaged file and an invalid package), `ItemEditorError`,
`ShareRepositoryImportError`. Anything else gets the generic message.
`AppLog.ui` / `AppLog.vault` are the loggers.

## UI feature contract

The feature sheets plug into the main window through one router and one dependency struct
(as built: every route opens its real feature screen). Each feature owns its folder; the init
signatures, `MainSheet`, the contexts, `FeatureDependencies` and `MainActions` are shared and
change only together with every caller.

**Router.** `MainViewModel.activeSheet: MainSheet?` (`App/Screens/Main/MainSheet.swift`).
`MainScreen` presents it with `.sheet(item:)` and maps each case to the entry view below. Setting
another route replaces the sheet; closing it sets `activeSheet` to nil (and opens the next pending
`.fxvault` import, if any). A lock sets it to nil and removes the main window.

| `MainSheet` case | Folder | Entry view | Context |
|---|---|---|---|
| `.itemEditor` | `ItemEditor/` | `ItemEditorScreen` | `ItemEditorContext(repositoryID, scope, mode: .add(ConfigKind) / .edit(id) / .fill(id) / .move(id), fillMatchesGitHub = false)` |
| `.newEnvironment` | `Environment/` | `NewEnvironmentScreen` | `NewEnvironmentContext(repositoryID)` |
| `.environmentSettings` | `Environment/` | `EnvironmentSettingsScreen` | `EnvironmentContext(repositoryID, environmentID)` |
| `.renameEnvironment` | `Environment/` | `RenameEnvironmentScreen` | `EnvironmentContext` |
| `.duplicateEnvironment` | `Environment/` | `DuplicateEnvironmentScreen` | `EnvironmentContext` |
| `.sync` | `Sync/` | `SyncScreen` | `SyncContext(repositoryIDs: Set<RepoID>?)` (nil: every repository with pending changes) |
| `.driftReview` | `Drift/` | `DriftReviewScreen` | `DriftReviewContext(repositoryID)` |
| `.createRepository` | `CreateRepo/` | `CreateRepoScreen` | `CreateRepoContext(accountLogin: String?, ownerLogin: String?)` (preselection only) |
| `.envImport` | `EnvFile/` | `EnvImportScreen` | `EnvImportContext(repositoryID, scope, fileURL: URL? = nil, defaultKind: ConfigKind? = nil, start: .chooser / .pasteEditor / .pasted(EnvPasteBuffer) = .chooser)` |
| `.envExport` | `EnvFile/` | `EnvExportScreen` | `EnvExportContext(repositoryID, scope)` |
| `.shareExport` | `Sharing/` | `ShareExportScreen` | `ShareExportContext(selection: ShareSelectionModel)` |
| `.shareImport` | `Sharing/` | `ShareImportScreen` | `ShareImportContext(fileURL)` |
| `.nearbySend` | `Sharing/` | `NearbySendScreen` | `NearbySendContext(selection: ShareSelectionModel?)` |
| `.nearbyReceive` | `Sharing/` | `NearbyReceiveScreen` | `NearbyReceiveContext()` |
| `.addRepositoryByName` | `Main/AddRepository/` | `AddRepositorySheet` (main window's own) | `AddRepositoryContext(accountLogin)` |

Every entry view is `struct XScreen: View { init(context: XContext, dependencies:
FeatureDependencies) }` (all `App/Screens/<Folder>/<XScreen>.swift`). The one non-sheet entry is
`Drift/DriftBannerView: init(report: DriftReportModel, onReview: @escaping () -> Void)`, shown by
`RepoDetailScreen` when the last drift check found something; `onReview` presents
`.driftReview`. The Nearby Chat window (v0.2.0) is not routed at all: it is its own scene,
`NearbyChatScreen(app:)`, whose view model gets `FeatureDependencies` from
`AppViewModel.nearbyChatDependencies()` (lock observers and gh readiness as for sheets; `present`
brings the main window forward, `refresh` and `select` do nothing). Contexts carry ids only (never values or names that could go stale): re-read
through the repositories. The one exception is `EnvImportContext.Start.pasted`, which carries
the text the user pasted on the detail table in an `EnvPasteBuffer` (a class compared and
hashed by identity, `SecretBytes` inside, redacted description); the import view model takes the
bytes out once.

**Dependencies (the only mechanism).** `FeatureDependencies`
(`App/Screens/Main/FeatureDependencies.swift`), built by `MainViewModel.featureDependencies` from
`AppContainer`; no environment values, no singletons. Build the feature's `@Observable` view model
in the entry view's init (`_viewModel = State(initialValue: XViewModel(context:dependencies:))`)
so view-model tests construct it with a `TestHarness`.

| Member | Use |
|---|---|
| `session` | The vault session (`authorizeEnvExport` / `authorizeShare` need it). |
| `config`, `catalog`, `github`, `sync`, `drift`, `envFiles`, `sharing`, `creation`, `chat` | The VaultData repositories (one instance each; `chat` is Nearby Chat's `ChatRepository`). |
| `cloner` | Clone (`RepoCloning`); never `creation.clone`. |
| `reauth` | `ReauthGate`. |
| `clipboard` | `ClipboardManager` (values: `copy`, commands: `copyCommand`). |
| `preferences` | Clone folder, gh override. |
| `passphraseGenerator` | 6-word passphrases (nil if the wordlist failed its check). |
| `clock` | `any VaultClock` for every timer (tests use `ManualClock`). |
| `connectivity` | `ConnectivityMonitor`: disable gh-backed actions while `!isOnline` (with `ConnectivityCopy.offlineHelp`). Nearby sharing does not depend on it. |
| `gitHubReachability` | Report gh outcomes (`record(error)` / `recordSuccess()`) for the "GitHub isn't responding" banner. |
| `actions` | `MainActions` (below). |
| `copyValue(of:)` | Decrypt, copy with the privacy markers, wipe. |
| `FeatureDependencies.reauthPrompt(for:)` | The Touch ID prompt for `.export`, `.share`, `.nearbySend`. |
| `touchIDStatus()` | The vault's `BiometricUnlockStatus` without a prompt (nil if unreadable). Re-authentication sheets offer Touch ID only when `.available`. |
| `syncService`, `driftService` | The live `SyncServicing` / `DriftServicing` seams (feature extensions in `Sync/`, `Drift/`). |
| `FeatureDependencies.preview()` | Dependencies over `AppContainer.preview()` with inert actions (SwiftUI previews only). |

`MainActions`:
- **Dismiss:** `@Environment(\.dismiss)` in the sheet (the router clears `activeSheet`).
- **Chain to another sheet:** `actions.present(MainSheet)` (for example drift review → item
  editor `.fill(id)` for the `promptFillValue` follow-up).
- **Refresh the main window:** local edits need nothing (every column observes the database).
  For gh-backed data call `actions.refresh(.catalog)` (re-list accounts and repositories, for
  example after a create), `.repository(id)` (re-read permissions and flags), `.drift(id)` (run
  the drift check of the open repository again, for example after a sync or a resolution).
- **Sync activity:** `let activity = actions.beginSyncActivity()` before `sync.startRun`, and
  `activity.end()` when `outcome()` returns, the run fails or the sheet closes (use `defer`). It
  suspends only the inactivity auto-lock and shows progress on the Sync button; a lock ends it.
- **Lock:** a lock removes the main window and its sheets. A view model holding typed passwords,
  passphrases or decrypted values outside SwiftUI state conforms to `LockObserving` and calls
  `actions.addLockObserver(self)` to wipe them in `vaultDidLock()`.
- **gh availability:** `actions.isGitHubReady()` before offering gh-backed actions.
- **Select a repository:** `actions.select(repoID)` selects it in the sidebar, at once or as soon
  as the vault observation lists it (New Repository uses it after staging).
- **Re-authentication:** `try await dependencies.reauth.authorizeEnvExport(with:
  .biometrics(FeatureDependencies.reauthPrompt(for: .export)), session: dependencies.session)` or
  `.password(text)`; for shares `authorizeShare(.fileExport / .nearbySend, with:session:)`. Treat
  `VaultError.cancelled` silently and offer the password field on `.passwordFallbackRequested`
  (`error.isCancellation`).
- **Copy:** `try dependencies.copyValue(of: itemID)`, or `dependencies.clipboard.copy(text)` for
  a value already decrypted for display; commands with `copyCommand`.
- **Errors:** `alert = error.presentation` (`View.errorAlert`); conform new error types to
  `PresentableError` in the feature folder.
- **Values:** entry only through `SecretValueEditor`; never log or keep values beyond the screen
  that shows them; sheets that reveal values may use `.screenCaptureProtected()`.

## Design system

v0.3.0 adopts the FractalX design language; tokens, components and usage rules are in
`docs/DESIGN.md`. `App/Helpers/Theme`: `Theme.Colors` (asset-catalog color sets with light and
dark variants: Ground, Surface, Surface2, Card, Ink, MutedText, SubtleText, FaintText, Hairline,
HairlineStrong, Brand (also the global accent), Warning, Success, Danger, InkBadge, DotGrid,
Shadow; the v0.2 names `accent`, `background`, `textPrimary`, `textSecondary` and `pending` are
aliases), `Theme.Typography` (Geist Sans and Geist Mono through `FontRegistry`, which falls back
to the system font for a missing face) and `Theme.TextStyle` (font, tracking, case; applied with
`.fxTextStyle`), `Theme.Spacing`, `Theme.Radius`, `Theme.Durations` (140 ms, spring),
`Theme.Opacity`, `Theme.Stroke`, `Theme.Shadow` and `Theme.Layout` (windows, columns, every sheet
size and the design component metrics). Shared components live in `App/Components/Design`.
Views never hardcode colors, fonts or metrics; feature folders do not define their own tokens;
`scripts/lint.sh` fails on literal colors and fonts outside Theme and Components/Design.

## Localization

One `Localizable.xcstrings` and one `InfoPlist.xcstrings` in the app, English only. Keys are
static and dot-namespaced (`String(localized: "root.locked.title", defaultValue: "...")`).
Packages throw typed errors and never ship user-facing text (SyncEngine's summary layout takes
an injected `ChangeSummaryVocabulary`). After adding or removing strings, run
`scripts/sync-strings.sh` (builds, then `xcstringstool sync` with the build's `.stringsdata`;
`--check` exits 1 when the catalog was out of date). A second run must report no change.

## Signing

Signing settings live only in `Config/*.xcconfig`:

- `Base.xcconfig`: ad-hoc (`CODE_SIGN_IDENTITY = -`), hardened runtime,
  `FXVault.entitlements` (not sandboxed). Optional `Local.xcconfig` include at the end.
- `Signed.xcconfig`: Developer ID (team id in that file), `FXVault-Signed.entitlements` (adds
  the keychain access group needed for Touch ID), provisioning profile "FX Vault Developer ID",
  secure timestamp. Enabled by a gitignored `Local.xcconfig` (see `Local.xcconfig.example`).
- `Tests.xcconfig`: the test bundle inherits the app's identity but no entitlements or profile.

Ad-hoc builds cannot use Touch ID (the keychain access group needs the provisioning profile).
Debug builds are "FX Vault Dev" (`io.fractalx.fxvault.dev`) and stay ad-hoc even with
`Local.xcconfig`: `Signed.xcconfig` resets the signing settings for `[config=Debug]` because the
Developer ID profile is for `io.fractalx.fxvault` only (decision 43).
Release builds are universal (arm64 + x86_64); see [RELEASING.md](RELEASING.md).

## CI

`.github/workflows/ci.yml` on pushes and pull requests to `main`:

- `macos-26` (blocking): newest GA Xcode 26, pinned XcodeGen (sha256-checked) drift check,
  `swift test`, ad-hoc `xcodebuild test`, `scripts/lint.sh`, `scripts/check-secrets.sh`.
- `xcode-27` (non-blocking, preview image): the same checks on Xcode 27.
- `gitleaks`: full-history secret scan with `.gitleaks.toml` (default rules; only the synthetic
  KAT vectors and the sample .env fixture are allowlisted). Needs the `GITLEAKS_LICENSE` secret
  for an organization repository.

`.github/workflows/release.yml` builds an ad-hoc DMG on tags and, when signing and notary
secrets exist, a signed and notarized one. Official releases are published from a maintainer's
Mac with `scripts/release-local.sh --publish`.

Every action is pinned to a commit SHA; workflow tokens default to read-only.
`scripts/ci-local.sh` runs the blocking checks locally.
