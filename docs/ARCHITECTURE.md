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
| `VaultStore` | VaultCore, GRDB | done | Database factory, migrations v1–v6, records, stores, observation. Stores blobs only |
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
  `ConfigSyncStatus.derive(Facts)` (priority: deleted, blocked, added, modified,
  unverifiedShare, synced).
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
- **Environment:** `ShellEnvironmentResolver.resolve()`, `ProcessEnvironmentBuilder.gh/git/ssh`,
  `ProcessIdentityModel`, `ShellEnvironmentModel`.
- **gh:** `GHLocator.locate(overridePath:shell:) -> GHInstallationModel`, `GHVersion`,
  `GHAuthService` (`accounts()`, `token(for:)`, `refreshToken`), `GHTokenCache` (`purge()` on
  lock), `ScopeChecker`, `GHCommandService.execute`, `GHCommandScheduler` (typed operations for
  every §8 A–C row; serial per account; throttled; retries), `GHRepoRef`, `GHRepoCreateRequest`,
  DTOs (`GHRepoDTO`, `GHSecretDTO`, `GHVariableListingModel`, `GHEnvironmentDTO`,
  `GHBranchPolicyDTO`, `GHLicenseTemplateModel`), `GHWriteRecordModel` (throttle seed).
- **ssh/git:** `SSHConfigParser`, `SSHAliasValidator`, `SSHAliasResolver` (D1, D2),
  `GitService` (D3 clone, D4–D6).
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
  `close`; `phase` (`NearbyChatPhase`), `ChatError`, `ChatTextSanitizer`. Ephemeral: no message
  history, everything wiped on close, abort or disconnect. Chat limits and timers are
  `Limits.chatMessageBytes`, `chatAttachmentBytes`, `chatMaxOpenAttachments`,
  `chatMaxOffersPerChat`, `chatMaxPeerFramesPerFloodWindow`, `chatMaxUnansweredPings`,
  `chatMaxBlankLines`, `chatMaxMarksPerCharacter` and `Timeouts.chatKeepaliveInterval`,
  `chatIdle`, `chatFloodWindow`, declared in
  SharingKit (`Chat/NearbyChatProtocol.swift`) as extensions of the VaultCore enums.
- **Import:** `ShareImportPlanner.plan(_:mode:local:fingerprint:)` → `ShareImportPlanModel`
  (chips, default actions, policy differences, replay warnings, provenance). VaultData's
  `ShareImporter` applies it in one transaction.
- `ShareError` (one `.invalidFile` for every file read failure).

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
`rename` (into a tombstone revives it), `revert`, `discardAll`, `fill(_:pushOnNextSync:)`,
`move(_:kind:scope:)` (Convert/Move). Each returns `ItemEditOutcomeModel{items, mutations:
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
  existing environment that B3 lists with reviewers, wait timers or app rules). Throws only
  `.locked` / `.persistenceFailed`; gh failures become
  `SyncBlockedChangeModel{change, reason: SyncBlockReason}`.
- `SyncPlanner.plan(_:includeDeletions:) -> SyncPlanModel` with ordered `SyncStepModel`s:
  create, environment upserts, patterns, guided renames, scope writes (repository first,
  variables before secrets), item deletes, environment deletes.
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
workingDirectory:clock:tokenCache:shellPath:sshConfigParser:)` is the `GHSchedulerProviding`
for every other repository: `shellEnvironment()`, `detectGH(overridePath:)`, `accounts()`,
`recheck(login:)`, `scopeFixCommands(for:)`, `purgeTokens()` (synchronous), `scheduler(for:)`
(one per account, seeded from the journal), `sshHostEntries()`, `mapSSHAlias(_:to:)`,
`testSSHAlias(_:for:)`. Errors: `GitHubEnvironmentError`.

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
  `fillValue(_:value:pushOnNextSync:)`, `moveItem(_:toKind:scope:)`, `discardAll(repositoryID:)`,
  `reveal(_:) -> SecretBytes` (caller wipes). Values are normalized on entry (D32;
  `ItemWriteResultModel.didStripTrailingNewlines`).
- Reads and streams: `changeSet(repositoryID:)`, `scopes(repositoryID:)`, `pendingCounts()`,
  `observeRepositories()`, `observeScopes(repositoryID:)`, `observeItems(repositoryID:scope:)`,
  `observePendingCounts()`.
- `RepoSnapshotMapper` is the only `ConfigItemState` → `ConfigItemSnapshotModel` mapping.

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
| 27 | §7.1 | The fill choice is a two-option radio group with both labels ("Fill local value (already on GitHub)" default, "Push this value on next Sync"), shown only for secrets already on GitHub |
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

### As built in v0.2.0 (flexible sharing, connectivity banner, nearby chat)

| # | Area | Decision |
|---|---|---|
| 43 | Sharing | The scope values stay `secret` / `environment` / `repository`; any mix is `repository`. Schema v2 exists only for partial environments (`deploymentBranchPolicy: null`) and is written only when one is present (lowest-version rule), so whole environments, the whole repository and repository-level selections stay readable by 0.1.x (SHARING-PROTOCOL.md §1.1) |
| 44 | Sharing | A branch policy travels only with a fully checked environment. A partial environment never changes the receiver's policy; when it is missing on the receiver it is created with GitHub's policy and patterns if GitHub lists it (synced), else with all branches (pending create). `.item` on an environment item is now a partial environment (supersedes decision 34) |
| 45 | Connectivity | `ConnectivityMonitor` applies the first path at once and later changes after 2 s on the injected clock; Low Data Mode is online, requires-connection is offline. `GitHubReachability` makes no calls of its own: the sidebar, repository detail, Add by name, the Sync sheet (preflight, start, and the last change of a run that says anything about GitHub), Create Repository (owners and templates) and the drift review report their gh outcomes |
| 46 | Connectivity | Nearby share and Nearby Chat are never gated by `isOnline` (peer-to-peer Wi-Fi works with no internet route, and a Mac with Wi-Fi on but joined to no network reports no connection). Nearby Chat is disabled only by `hasNetworkInterface == false`. Clone is disabled offline too; the toolbar Import .env stays enabled (local only). A Sync sheet left open when the Mac goes offline cannot start a run or review deletions and says why in its footer |
| 47 | Nearby | Listener, browser and connection set `includePeerToPeer` (AWDL); the protocol bytes and KATs are unchanged. 0.1.x does not use AWDL, so 0.1.x and 0.2.0 Macs meet only on a shared network |
| 48 | Chat | Chat is domain-separated from share by its Bonjour type (`_fxvault-chat._tcp`) and label prefix (`fxvault/chat/v1`); the handshake moved, unchanged, into the internal `NearbyKeyExchange` used by both. Chat KATs are cross-checked with Python like the share KATs |
| 49 | Chat | Ephemeral by construction: the session keeps no history, the window's transcript lives in the view model only, and close, lock, sleep, screen lock, disconnect, timeout and End Chat wipe it. Idle 10 min, keepalive PING every 30 s (abort after 2 unanswered), no overall limit; the responder waits for a connection without a timer |
| 50 | Chat | Attaching asks ReauthGate before the picker opens and reuses `ShareAuthorizationPurpose.nearbySend` (its Touch ID prompt). The offer carries a manifest only; the value is decrypted when the peer asks and only if the item still has the offered name, kind and scope. "Save to my vault" goes through the share import preview and `SharingRepository.apply` |
| 51 | Chat | The chat window needs an unlocked vault; closing the main window locks the vault (D16) and so ends the chat. A responder whose unverified peer drops before HELLO, or leaves before the code is shown, re-advertises and returns to the people list without an "ended" screen or a failed-handshake count; only listener failures (no connection accepted) count, 3 in a row at most. `incomingConnection` clears the "visible" chip. There is no accept/decline step before the code comparison (open product question) |
| 52 | Nearby | Chat advertises the user's sanitized display name (Preferences › General › "Name for nearby Macs", else the macOS full name) as its Bonjour instance name. Nearby share and receive use the same name in HELLO (`ShareLocalIdentityModel.nearby(preferences:)`) but keep random Bonjour instance names |
| 53 | Chat | Flood limits: more than 100 TEXT/offer/request/decline/PING frames in 10 s, or more than 32 offers per chat, abort with `unexpectedMessage`; the window keeps 1,000 messages. Text and names drop every invisible character (`UnicodeScalarPolicy.isInvisible`); chat text keeps one blank line in a row and four combining marks per character. Messages are not selectable: Copy goes through `ClipboardManager`. Late async results (send, offer, request, a save preview) of a chat that ended are dropped. An offer's value provider refuses a value whose `value_fp` changed since the offer. Discovery uses the `local.` domain and filters this Mac by its registered name |
| 54 | Sharing | A missing partial environment whose items are all skipped is not created (`ShareEnvironmentPlanModel.createsEnvironment`); a nearby DECISION carries such an environment's id only with an accepted item. A tree opened for one item keeps sharing that item even if it is its environment's only item, until the checks change. Share import previews read GitHub only when online (`FeatureDependencies.checksGitHub`), and their "Import repository" button, the drift review's Refresh and resolutions, and Create Repository's Sync Now… are disabled offline with `ConnectivityCopy.offlineHelp`. The connectivity debounce is not restarted by more updates of the same transition; a reconnect cancels the previous one and re-lists drift only when the last check failed, never ran or was skipped offline |


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
  (`makeReport(infoDictionary:capabilities:probe:)`, pure) and `DiagnosticReportModel` (explicit
  `null`s, sorted keys).
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
  `ghPathOverride`, `isRecoveryKeyConfirmationPending`, `hasAnsweredTouchIDOffer`,
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
- `GHStatusProbing`: `GitHubEnvironmentStatusProbe(github:overridePath:)` (`detectGH` then
  `accounts()`) and `FixedGHStatusProbe`. `GHStatusModel`: `.checking`, `.unknown`,
  `.ready(version:path:)`, `.notInstalled`, `.outdated(found:required:)`, `.untrusted(path:)`,
  `.noAccounts(version:path:)`, `.failed`; `needsSetup`, `isReady`.

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
  version and why 2.97 is required) / untrusted / login / failed; copyable `brew install gh`,
  `brew upgrade gh`, `gh auth login`; **Check Again**; **Not Now** (work without gh until the next
  launch or until gh is ready).
- `Preferences`: General, Security, **Accounts** (`AccountsSettingsViewModel`: gh path and
  version, per account token state, scopes with copyable fix commands, SSH alias picker from
  `~/.ssh/config`, **Test** "Authenticates as <login>", **Re-check**), Advanced.
- `Main` (§10.4), `MainViewModel` owns:
  - `SidebarViewModel` (`Main/Sidebar`): vault repositories observed (work without gh), gh
    accounts and catalogs loaded when gh is ready; `SidebarGrouping.sections(_:query:)` (pure)
    groups account → owner (Personal, organizations in gh's order, others by name) → repositories,
    with badges (private, archived, fork, unavailable, not on GitHub), scope warnings, SAML and
    truncation notes and search; Import, Clone, Share…, Remove from vault (confirmed); Add
    repository by name (`Main/AddRepository`).
  - `ScopeListViewModel` (`Main/ScopeList`): "Repository" plus environments
    (`observeScopes`), pending dot, value-missing count, context menu Settings / Rename /
    Duplicate / Export .env / Share / Revert / Delete (confirmed), "+ New Environment" (admin).
  - `RepoDetailViewModel` (`Main/RepoDetail`): header (owner/name, visibility, capability chip,
    Clone, Refresh, drift banner, deployment branches with Edit, plan note on private
    repositories, read-only explanation) and `ConfigTableView` (Secrets | Variables over one
    `Table`; masked secrets with the eye toggle, "Value missing", plaintext variables; Reveal,
    Copy, Edit / Fill Value, Convert or Move, Revert, Delete). The Add split button adds one
    item of the tab's kind and offers Paste Multiple… and Import .env File…; ⌘V in the detail
    column (`onPasteCommand(of: [.plainText], validator: validatePaste)`, `handlePaste(_:)`
    reads the providers) opens the import preview prefilled. All three pass the tab's kind as `defaultKind` and the open scope as the
    target. Revealed values re-mask after
    `Timeouts.revealRemask` (injected clock), on resign active, on scope change and on lock.
    The drift check runs when a repository opens (`DriftRepository.detectOnOpen`).
  - Connectivity (v0.2.0): `ConnectivityBannerView` above the three columns shows
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
    `GitHubReachability` (decision 45).
  - Toolbar: New Repository, Import .env, Share menu (File… / Nearby… / Receive Nearby… /
    Nearby Chat…, which opens the chat window), Lock,
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
    Secret…". Fill defaults to "Fill local value (already on GitHub)". Secret → variable asks
    first (Cancel is the default). The typed value is wiped after save, on close and on lock.
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

**Components** (`App/Components`): `SecretValueEditor`, `MaskedValueCell` (display-only: masked /
revealed / plain / missing, the view model owns reveal state), `CommandRow`,
`RecoveryKeyGridView`, `PassphraseView`, `StatusChip`, `EmptyStateView`, `SyncToolbarButton`,
`GHStatusRow`, `PasswordStrengthMeter`, `NewPasswordFields`, `CenteredCard`, `WindowAccessor`,
`View.screenCaptureProtected()`, `View.errorAlert(_:)` (`ErrorAlert`). Shared by the feature
sheets: `ConfigEditorSheet(title:subtitle:primaryTitle:isPrimaryEnabled:isWorking:onCancel:
onPrimary:content:)` (header, grouped form, Cancel = Esc, primary = Return) with
`ConfigEditorNoteModel` / `ConfigEditorNoteView`; `BranchPolicyFormModel` (pure: All / Protected
branches only / Selected patterns, `BranchPatternValidator`, at most 50 rules, `draft`,
`isReadyToSave` waits for a typed but unadded rule) and `BranchPolicyEditorView(form:isEnabled:)`
(form sections; used by Environment Settings, New Environment and New Repository). Helpers:
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
| `.itemEditor` | `ItemEditor/` | `ItemEditorScreen` | `ItemEditorContext(repositoryID, scope, mode: .add(ConfigKind) / .edit(id) / .fill(id) / .move(id))` |
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

`App/Helpers/Theme`: `Theme.Colors` (semantic asset-catalog colors with light and dark variants:
Accent, Background, Surface, TextPrimary, TextSecondary, Success, Warning, Danger, Pending),
`Theme.Typography` (including `sasCode`), `Theme.Spacing`, `Theme.Radius`, `Theme.Durations`,
`Theme.Opacity` and `Theme.Layout` (windows, columns and every sheet size: `editorSheetWidth`,
`createRepo*`, `sync*`, `drift*`, `env*`, `share*`). Views never hardcode colors, fonts or
metrics; feature folders do not define their own tokens.

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
