# FX Vault - Sharing formats and protocol

Implemented in `Packages/FXVaultKit/Sources/SharingKit`. This document records the wire formats
as built (plan §9 plus the decisions made during M6 implementation). Known-answer vectors are
pinned in `Tests/SharingKitTests/Fixtures/nearby_kat.json`, `chat_kat.json`, `team_kat.json` and
`space_kat.json`; the independent generators
(`Fixtures/kat/crosscheck.py`, Python `cryptography`; `Fixtures/kat/NearbyProtocolReference.swift`)
produce byte-identical output.

## 1. Payload: `SharePackageModel` (schema 1 and 2; 3 for folders, §1.3)

JSON, keys sorted, dates ISO-8601 UTC with `Z`. `value` and `githubUpdatedAt` are always present
(explicit `null` when absent). `deploymentBranchPolicy` is an object, or an explicit `null` for a
partial environment (schema 2 only, §1.1).

```json
{ "schema": "io.fractalx.fxvault.share", "schemaVersion": 1 | 2,
  "packageId": "<uuid>", "createdAt": "2026-10-14T10:00:00Z",
  "producer": {"app": "FX Vault", "version": "1.0.0"},
  "sender": {"displayName": "<sanitized, ≤ 63 bytes>"},
  "scope": "secret | environment | repository",
  "repository": {
    "host": "github.com", "owner": "<owner>", "name": "<repo>", "githubRepoId": "<node id> | null",
    "secrets":   [{"id": "<uuid>", "name": "API_KEY", "value": "<utf-8> | null",
                   "valueState": "present | missing", "githubUpdatedAt": "<date> | null",
                   "syncState": "synced | pending"}],
    "variables": [ ... same shape ... ],
    "environments": [{"id": "<uuid>", "name": "production",
                      "deploymentBranchPolicy": {"type": "all | protected | custom",
                                                 "patterns": [{"name": "release/*", "type": "branch | tag"}]}
                                                | null,
                      "secrets": [ ... ], "variables": [ ... ]}] } }
```

- **Entry ids** (`ShareEntryID`, a UUID) are on every item and environment, in one id space.
  They exist so the nearby DECISION can name what the receiver accepted.
- **Manifest** = the same document with every `value` set to null (`valueState` kept). Value
  hashes are never included.
- **Scopes** describe the contents; the receiver merges every scope the same way (nothing that
  is missing from a package is ever deleted):
  - `secret`: exactly one item (secret or variable), at repository or environment level.
  - `environment`: exactly one whole environment (with its policy) and no repository-level items.
  - `repository`: any other combination, including a subset of the repository level, several
    environments, and partial environments. No new scope value was needed: the v1 validator
    already accepts any mix under `repository`.

### 1.1 Schema versions and compatibility (v0.2.0)

| `schemaVersion` | Written by | Meaning |
|---|---|---|
| 1 | 0.1.x, and 0.2.0 whenever possible | Every environment carries its `deploymentBranchPolicy` |
| 2 | 0.2.0 when needed | Adds **partial environments**: `deploymentBranchPolicy: null` plus at least one item |

- **Lowest version rule.** A package is written with the lowest version that can hold it
  (`SharePackageModel.requiredSchemaVersion(for:)`): 2 only when at least one environment is
  partial. The whole repository, whole environments, the repository level (all or some of it)
  and single repository-level items are still written as v1.
- **0.1.x → 0.2.0.** Every v1 file and nearby manifest written by 0.1.x imports unchanged
  (pinned by `SharingKitTests/Fixtures/item-v1-0.1.1.json` and
  `VaultDataTests/Fixtures/Sharing/repository-v1-0.1.1.fxvault`, both written by 0.1.1). A v1
  environment always carries its policy, so 0.1.x semantics are kept: a single
  environment-level item from 0.1.x still offers its environment's policy as a "Deployment
  branches differ" row (Keep mine by default).
- **0.2.0 → 0.1.x.** v1 packages import in 0.1.x. A v2 package (anything with a partial
  environment, including a single environment-level secret or variable) is rejected by 0.1.x:
  its decoder requires a policy object, so a `.fxvault` file shows "Wrong passphrase or damaged
  file" and a nearby MANIFEST aborts. The workaround is to check the whole environment (v1) or
  to update the receiver.
- A v1 document with a `null` or missing policy is rejected (`branchPolicyRequired`); a v2
  document may also contain only whole environments. A repository package with a version other
  than 1 and 2 is `unsupportedSchemaVersion` (`SharePackageModel.repositorySchemaVersions`);
  version 3 is a folder (§1.3).

### 1.3 Folders: schema 3 (v0.7.0)

A copy of a folder is scope `folder`, `schemaVersion` 3, and carries a `folder` object instead of
`repository`:

```json
{ "schema": "io.fractalx.fxvault.share", "schemaVersion": 3, "packageId": "<uuid>",
  "createdAt": "…", "producer": {…}, "sender": {…}, "scope": "folder",
  "folder": {"name": "Mobile App",
             "secrets":   [{"id": "<uuid>", "name": "FIREBASE_API_KEY", "value": "<utf-8> | null",
                           "valueState": "present", "githubUpdatedAt": null, "syncState": "pending"}],
             "variables": [ ... same shape ... ]} }
```

- The validator requires a valid folder name (`FolderNameValidator`, NFC), at most
  `Limits.maxFolderItems` (1,000) items, every item `valueState: present` (a folder item always
  has a value), unique names per kind, and GitHub item names. A document with both `folder` and
  `repository`, or a `folder` with any other scope, does not decode.
- In memory (`SharePackageModel`) the items sit at repository level of a `repository` block with
  an empty owner and name and no environments, so manifests, filtering, summaries and wiping work
  unchanged; `folder` holds the name.
- **Import Into a repository**: `SharePackageModel.intoRepository(owner:name:githubRepoID:environmentName:)`
  turns the folder into an ordinary package for the chosen repository, its items at repository
  level or in a partial environment (schema 2) of the chosen environment, with the same package
  id. Only that converted package is planned: `ShareImportPlanner` refuses a folder package, and
  nearby share (§4) refuses one in either direction.
- **Save as Folder**: `FolderRepository.save(_:as:conflicts:)` writes the items into a new folder
  (by default named as the sender's) or merges them into an existing folder (names it has are
  kept unless Replace is chosen), normalizes values (D32) and records the package id in
  `imported_share_packages` like an import.
- 0.6 and older reject version 3 (`unsupportedSchemaVersion`): a `.fxvault` folder file shows
  "Wrong passphrase or damaged file" there.

### 1.2 Branch policy rule

An environment's deployment branch policy travels **only when the environment itself is
selected**: in the scope tree its checkbox is fully checked (checked directly, or every one of
its items is checked), or the selection is `.environment` / `.repository` / a subset's
`environmentIDs`. An environment reached only through some of its items is a partial environment:
it carries the selected items and no policy. Consequences on the receiver (§5):

- an existing environment keeps its policy (no "Deployment branches differ" row);
- a missing environment is created with GitHub's policy and patterns when GitHub lists it
  (created as synced, nothing pending), otherwise with all branches (GitHub's default for a new
  environment, pending create);
- a missing partial environment whose items the receiver all skips is not created
  (`ShareEnvironmentPlanModel.createsEnvironment`), and the receiver's nearby DECISION names
  such an environment only together with at least one accepted item of it, so skipping the only
  item of a `secret`-scope share declines cleanly.

An environment without items and without a policy says nothing and is invalid
(`branchPolicyRequired`); the nearby filter drops it (§4 step 9). One scope-tree exception: a
tree opened for one item ("Share this secret…") shares that item alone (`.item`, no policy)
even when it is its environment's only item, until the user changes the checks.

`SharePackageValidator` (modes `.manifest` and `.payload`) rejects, among others: a schema or
version other than the above (§1.1); a missing policy in a v1 document, in an `environment`-scope
document or on an environment without items (`branchPolicyRequired`); producer or sender fields that are not already sanitized; a host
other than `github.com`; invalid owner or repository names (owners: `OwnerLoginValidator`, ASCII
letters, digits, `-` and, since v0.3.1, `_` for Enterprise Managed User owners such as
`mona-cat_acme`, never first, at most 39 characters; repositories: `.`, `..`, `*.git`); a `githubRepoId`
over 128 characters; environment names that fail `EnvironmentNameValidator` (NFC, no C0/C1,
bidi, zero-width or edge whitespace, no `/`, no dot segments); item names that are not already
uppercase GitHub names; duplicate environments, items (per kind and level) or entry ids; more
than 100/500/100/100 secrets/variables at repository/environment level; values in a manifest;
empty, non-UTF-8 or over-48,000-byte values (measured after trailing CR/LF is stripped);
`valueState` not matching the value; patterns that are invalid, duplicated, more than 50, or
present without a custom policy; and content that does not match the declared scope. A secret
and a variable may share a name within a scope, as on GitHub.

## 2. File: `.fxvault` v1

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | magic `46 58 56 41 55 4C 54 1A` |
| 8 | 2 | formatVersion u16 BE = 1 |
| 10 | 2 | headerLength u16 BE = 64 (must be exactly 64) |
| 12 | 1 | kdfId = 1 (Argon2id v1.3) |
| 13 | 1 | aeadId = 1 (AES-256-GCM) |
| 14 | 4 | opsLimit u32 BE (3) |
| 18 | 4 | memLimitKiB u32 BE (65536) |
| 22 | 1 | parallelism = 1 |
| 23 | 1 | flags = 0 |
| 24 | 16 | salt |
| 40 | 12 | nonce |
| 52 | 12 | reserved, zero |
| 64 | n | ciphertext ‖ tag (16); AAD = header bytes 0..<64 |

- Key: Argon2id(normalized passphrase, salt, t, m KiB, p = 1) → 32 bytes, through the injected
  `KeyDeriving` (VaultData adapts VaultCrypto's Argon2id; memory KiB × 1024 = bytes).
- Reader order: size ≤ 16 MiB + 80 → magic → version → headerLength → kdf/aead ids → bounds
  (1 ≤ t ≤ 10, 8192 ≤ m ≤ 1048576 KiB, p = 1, flags and reserved zero) → **only then** the
  passphrase (`FxVaultFileCodec.inspect` never calls the KDF) → Argon2id → GCM open → JSON
  (≤ 16 MiB) → validate (payload mode) → replay check → preview.
- Every read failure up to JSON decoding is `ShareError.invalidFile`, shown as "Wrong
  passphrase or damaged file". Validation failures are `invalidPackage(...)`.
- Writer: fresh salt and nonce every time; `ReauthGate(.share)` first; written with
  `SecureFileWriter` (0600).
- KAT: key `0x42 × 32`, t = 3, m = 65536, salt `80..8f`, nonce `90..9b`, payload
  `{"schema":"fxvault.share/1"}` → 108-byte file, header
  `46585641554c541a0001004001010000000300010000010080…8f 90…9b 00×12`.

## 3. Passphrase

Six words from the EFF large wordlist minus the four hyphenated words (`drop-down felt-tip
t-shirt yo-yo`): 7,772 words, about 77.5 bits, drawn with `SystemRandomNumberGenerator`, joined
with `-`. The bundled list is verified by SHA-256 (`addd3553…996b903e`) before use. Input is
lowercased, split on non-letters, and must be exactly six listed words; errors report the word
count or the position of an unknown word, never the typed text.

## 4. Nearby protocol v1

**Roles:** I (initiator, sender: browses and connects) and R (responder, receiver: advertises
only while "Receive nearby" is open).

**Transport (`NWNearbyTransport`, `NWNearbyBrowser`):** Bonjour `_fxvault-share._tcp` with a
random service instance name per session; TXT holds only `v=1`. TCP with `acceptLocalOnly` and
cellular prohibited. The listener accepts only the first connection (a second is `secondPeer`).
Framing: u32 BE length prefix (`NearbyLengthFramer`). Local Network denial is reported as
`NearbyTransportFailure.localNetworkDenied`.

**Peer-to-peer Wi-Fi (v0.2.0):** the listener, the browser and the connection all use
`includePeerToPeer = true` (`NWNearbyConfiguration.parameters()`), so Bonjour and TCP also run
over AWDL, the link AirDrop uses. Two Macs with Wi-Fi turned on find each other with no shared
network, router or internet; on a shared network the infrastructure path still works. `acceptLocalOnly` still refuses anything that is not on the
local link, and cellular stays prohibited. The protocol bytes are unchanged (the KATs below
still pass); only reachability changes, and with it who can see the advertisement: anyone
within Wi-Fi range, not only people on the same network. The share advertisement carries a
random instance name and `v=1`; the security of a session still rests on the code comparison.
0.1.x builds browse and listen without AWDL, so a 0.1.x Mac and a 0.2.0 Mac only meet on a
shared network. Verified by parameter tests; the two-Mac check with Wi-Fi networks disconnected
is manual (RELEASING.md).

### Handshake

```
(1) I→R HELLO_I 0x01: maxVerI | suiteI=0x01 | C(32) | u16 len + nameI (sanitized NFC ≤ 63 B)
      C = SHA256(LP("fxvault/nearby/v1/commit") ‖ maxVerI ‖ suiteI ‖ LP(pkI) ‖ LP(nI))
(2) R→I HELLO_R 0x02: maxVerR | suiteR | pkR(32) | nR(32) | u16 len + nameR
      R rejects an unknown suite here (unsupportedSuite)
(3) I→R REVEAL_I 0x03: pkI | nI      R recomputes C; mismatch ⇒ ABORT + security warning
(4) abort unless suiteI == suiteR (I: suiteMismatch); ver = min(maxVerI, maxVerR) ≥ 1
    TH = SHA256(LP("fxvault/nearby/v1/transcript") ‖ maxVerI ‖ maxVerR ‖ ver ‖ suiteI ‖ suiteR
                ‖ LP(C) ‖ LP(pkI) ‖ LP(nI) ‖ LP(nameI) ‖ LP(pkR) ‖ LP(nR) ‖ LP(nameR))
    ss = X25519 (low-order and all-zero results abort with invalidKey)
    SAS = BE_UInt64(HKDF-SHA256(ss, salt TH, "fxvault/nearby/v1/sas", 8)) mod 10^6 → "ddd ddd"
    k_i2r / k_r2i = HKDF-SHA256(ss, TH, "fxvault/nearby/v1/key/i2r" | ".../r2i", 32)
(5) both users compare the SAS; "Codes match" / "Don't match"
(6) CONFIRM 0x10 (encrypted, body 0x01) from each side after its user confirms
```

### Transfer

| Step | Frame | Body |
|---|---|---|
| 7 | I→R MANIFEST 0x11 | Only after I's user confirmed, `ReauthGate(.nearbySend)` passed and R's CONFIRM arrived. A manifest may span several 0x11 frames: the first starts with a u32 BE total length, the following frames carry the rest. |
| 8 | R→I DECISION 0x12 | `accept (1) ‖ u32 count ‖ count × 16-byte entry ids`; at most 4,093 ids; accepting needs at least one id. Unknown ids abort (`unknownItemIDs`). |
| 9 | I→R PAYLOAD_CHUNK 0x13 … PAYLOAD_END 0x14 | Chunks carry the JSON of the package filtered to the accepted ids; END is `u64 BE length ‖ SHA-256(payload)`. A mismatch aborts (`payloadMismatch`). The filter keeps an environment when one of its items is accepted, or when its own id is and it carries a policy; it never adds or removes a policy and keeps `schemaVersion`. |
| 10 | R→I RESULT 0x15 | `ok (1)` |
| 11 | CLOSE 0x7E | Empty. R finishes right after sending RESULT or a decline; I sends CLOSE after RESULT or a decline. A CLOSE that arrives early is `peerAborted(.cancelled)`. |
| any | ABORT 0x7F | One `NearbyAbortCode` byte: 0x01 protocolError, 0x02 unsupportedVersion, 0x03 unsupportedSuite, 0x04 commitmentMismatch, 0x05 invalidKey, 0x06 decryptionFailed, 0x07 sasRejected, 0x08 timeout, 0x09 cancelled. Plaintext before keys exist; after that, a plaintext ABORT is accepted only until the first encrypted frame from the peer has arrived (the peer may not have keys yet). |

**Encrypted frame:** `[ver][type][seq: u64 BE][ciphertext][tag 16]`, AAD = the first 10 bytes,
nonce = `0^4 ‖ seq`, AES-256-GCM with the direction's key. Sequence numbers are exact per
direction, starting at 0; replay, reorder, reflection (wrong direction key) and any header
change abort.

**Limits:** handshake frames ≤ 512 B, encrypted frames ≤ 64 KiB, payload ≤ 16 MiB,
seq < 2^32, one peer.

**Timers** (`Timeouts`, run on the injected `VaultClock`):

| Phase | Timer |
|---|---|
| awaitingHello, awaitingReveal | handshake, 30 s |
| comparingCodes | SAS, 120 s |
| receivingManifest, receivingPayload | idle, 30 s, restarted on every frame |
| phases waiting for a person (reauth, the receiver's decision, the final confirmation) | session limit only |
| whole session | 10 min |

**Aborts** wipe the session keys, never resume and never retry automatically. After an abort
that follows REVEAL, or two failed handshakes in a row (`NearbyFailureTracker`), the app shows
"Someone nearby may be trying to intercept this share."

**Vectors** (inputs in the JSON: fixed skI/skR, nI/nR, names "Alice's Mac" and "Bob's Mac"):
C `c02e9519…a4d94dad` (unchanged from the research value), TH `94d1a5c5…10fa1fb9`,
SAS **835 921** (the research SAS 762 202 no longer applies because TH now binds both
suites and both max versions), SAS with nameR changed `242 922`, CONFIRM I→R seq 0
`0110…164a`.

## 5. Receiver merge (`ShareImportPlanner`)

Pure planner; VaultData's `ShareImporter` applies the plan in one transaction (re-encrypting
with the receiver's DEK under new row ids, setting `provenance = share` with the package id and
unverified sender name, and recording the package in `imported_share_packages`).

- **Blocked** when the repository is not imported, when its name does not match, or when the
  package has a `githubRepoId` that differs from the local `github_id` (including a local nil:
  a repository created locally and not yet pushed).
- **Replay warnings** (need confirmation): already imported, `createdAt` older than 7 days,
  `createdAt` older than local changes.
- **Item chips:** new, fillsMissingValue, valueNotIncluded, existsLocally (manifest preview),
  same / differs (payload only), otherKindExists (skip + warning), deletedLocally (forced skip).
- **Defaults:** add; fill; skip when the fingerprint is identical; **keep mine** when different
  (overwrite and overwrite-all are available); an item that only exists under the other kind is
  skipped with a warning.
- **Partial environments (v2):** no policy row; an existing environment keeps its policy and
  only the incoming items are planned. A missing one is created with GitHub's policy and
  patterns when GitHub lists it (synced, nothing pending; `ShareImporter`), otherwise with all
  branches (pending create). Only whole environments count for the `olderThanLocalChanges`
  replay warning.
- **Environments:** missing ones are created (pending unless GitHub already lists them). A
  different branch policy is its own row, defaulting to keep mine. Widening (anything → all,
  custom → protected, or a new pattern containing `*`, `?` or `[`) needs a second confirmation.

## 6. VaultData integration (`SharingRepository`)

SharingKit stays pure; VaultData's `SharingRepository` connects it to the vault.

- **Authorization.** `.fxvault` export needs `ReauthGate.authorizeShare(.fileExport, …)` and a
  nearby MANIFEST needs `.nearbySend`. Each authorization is single-use and invalidated by any
  lock, unlock or key rotation (SECURITY-MODEL.md §6).
- **Export.** The selection (`ShareSelectionModel` item, environment, repository, or
  `subset(ShareSubsetModel)`: whole environments plus individual items, any combination) is built
  into a `SharePackageModel` with values decrypted inside `VaultSession.read`, sealed with a
  fresh 6-word passphrase by `FxVaultFileCodec(deriver: Argon2idSharingDeriver())` and written
  0600 by `SecureFileWriter`. The passphrase is returned once (`SecretBytes`) and never stored.
  Value-missing secrets travel by name only.
- **Import.** `readFile(at:)` checks the header before any passphrase is asked for;
  `openFile(_:passphrase:checkGitHub:)` normalizes the typed passphrase, decrypts, validates and
  plans against local state (keyed fingerprints, optional GitHub listing) into a
  `ShareImportDraftModel` that owns a copy of the values and wipes it on apply, discard or
  deinit. Every read failure is the single `.invalidFile` error.
- **Apply.** `apply(_:plan:confirmReplay:)` re-plans inside the write transaction and refuses
  with `.planOutdated` if the result differs from what the user saw. Rows are re-encrypted with
  the receiver's keys under new row ids, carry `provenance = share` (package id plus the
  unverified sender name) and the package id is recorded in `imported_share_packages`, all in
  one transaction. Replays need `confirmReplay`.
- **Implementation choices:** an incoming variable without a value is skipped and reported (a
  variable row must hold a value); an environment GitHub already lists is created as synced; an
  add GitHub already has is imported as synced.
- **Nearby.** `makeNearbySender` / `makeNearbyReceiver` wrap `NearbySession` over a
  `NearbyTransport` (`NWNearbyTransport` in the app, `InMemoryTransportPair` in tests). The
  receiver previews the manifest, decides, previews the payload and applies through the same
  importer; events forwarded to the UI never carry values.

## 7. Nearby chat: `fxvault-chat/v1` (v0.2.0, experimental; chat version 2 in v0.4.0, §7.1)

Implemented in `SharingKit/Chat/` (`NearbyChatSession` actor over the pure `NearbyChatMachine`).
Bryan's decisions: chat is 1:1 and **ephemeral** (messages live only in memory and are wiped
on close, lock or disconnect; nothing is written to disk), a secret or variable can be attached
(names only until the receiver asks; saving goes through the normal share import), and it works
over peer-to-peer Wi-Fi like nearby share (§4).

**Domain separation from share.** Chat has its own Bonjour service type `_fxvault-chat._tcp`
(listed in `NSBonjourServices`) and its own label prefix: every hash and HKDF label of the
handshake is `fxvault/chat/v1/…` instead of `fxvault/nearby/v1/…` (`NearbyPurpose`,
`NearbyLabels`). The commitment, transcript, SAS and both direction keys therefore differ for
the same key material. A share initiator talking to a chat responder (or the reverse) fails the
commitment check at REVEAL (`commitmentMismatch`, plaintext ABORT); even if a relay skipped
that check, the codes would differ and no CONFIRM would open under the other purpose's keys.
Share frame types (MANIFEST, DECISION, …) are `unexpectedMessage` in a chat and chat types are
`unexpectedMessage` in a share. Tested both ways at the state-machine and session level.

**Transport.** `NWNearbyTransport.advertisingChat(displayName:)` publishes `_fxvault-chat._tcp`
under the user's sanitized display name (≤ 63 bytes, the Bonjour limit; random if nothing is
left), TXT `v=1`, only while the chat window is open, and accepts one connection.
`NWNearbyBrowser(purpose: .chat)` lists peers; `NearbyEndpointModel.displayName` is the
sanitized, **unverified** advertised name. Same TCP parameters, framing and peer-to-peer Wi-Fi as
share. The advertised name is visible to every Mac in Wi-Fi range while the window is open.

**Handshake.** Steps 1–6 of §4 unchanged (`NearbyKeyExchange`, shared with share) with the chat
labels. The responder waits for a connection without a timer; after `.connected` the initiator
sends HELLO_I. Events: `incomingConnection` (responder only: someone connected, nothing known
yet), `peerConnected(name)` when the peer's HELLO arrives (unverified name), `sasReady(code)`,
`peerConfirmedSAS`, `verified` once both users pressed "Codes match".

**Encrypted frames** (layout, AAD, nonces, per-direction keys and exact sequence numbers as in
§4; frames ≤ 64 KiB; anything out of order, replayed, reflected, truncated or oversized aborts):

| Type | Frame | Body | Rules |
|---|---|---|---|
| 0x10 | CONFIRM | `0x01` | Only while comparing codes. |
| 0x20 | TEXT | UTF-8, 1…4,096 bytes (`Limits.chatMessageBytes`) | Only when verified. Over the limit: `oversizeFrame`; empty or invalid UTF-8: `malformedFrame`. Both sides sanitize (`ChatTextSanitizer`: CR/LF and U+2028/9 → LF, other C0/C1/DEL, bidi controls, zero-width characters except ZWJ and every other invisible character (`UnicodeScalarPolicy.isInvisible`: General_Category Cf such as tag characters, soft hyphen and invisible operators, Hangul fillers, U+034F) removed, NFC, at most one blank line in a row (`Limits.chatMaxBlankLines`) and four combining marks per character (`Limits.chatMaxMarksPerCharacter`), trimmed); a message left empty is dropped. |
| 0x21 | ATTACHMENT_OFFER | `id(16) ‖ manifest JSON` | A share manifest (no values) of scope `secret`: exactly one secret or variable with `valueState = present`, passing `SharePackageValidator` (manifest). In a chat of version 2, also scope `repository` or `environment` (§7.1). Duplicate id: `malformedFrame`; more than 8 open offers (`Limits.chatMaxOpenAttachments`) or more than 32 offers in the chat (`Limits.chatMaxOffersPerChat`): `unexpectedMessage`. |
| 0x22 | ATTACHMENT_REQUEST | `id(16)` | Receiver → sender ("Save to my vault"); once per offer. Unknown id: `unknownItemIDs`. |
| 0x23 | ATTACHMENT_PAYLOAD | `id(16) ‖ u32 totalLength ‖ chunk` | Sender → receiver, only for a requested offer, chunks in order with a constant total ≤ 512 KiB (`Limits.chatAttachmentBytes`; a configuration ≤ 16 MiB, §7.1). The complete JSON must validate (payload mode) and equal the offer apart from the values, else `payloadMismatch`. One transfer at a time. |
| 0x24 | ATTACHMENT_DECLINE | `id(16)` | Receiver: dismisses an offer it has not requested. Sender: withdraws an offer whose value it cannot supply. Anything else aborts. |
| 0x30 / 0x31 | PING / PONG | empty | Keepalive; a PONG without an outstanding PING is `unexpectedMessage`. |
| — | Flood limit | — | More than 100 TEXT, ATTACHMENT_OFFER, ATTACHMENT_REQUEST, ATTACHMENT_DECLINE and PING frames from the peer within 10 s (`Limits.chatMaxPeerFramesPerFloodWindow`, `Timeouts.chatFloodWindow`, by receive time) abort with `unexpectedMessage`. |
| 0x7E | CLOSE | empty | Ends a verified chat normally (`peerClosed`); before verification it is `peerAborted(.cancelled)`. |
| 0x7F | ABORT | one `NearbyAbortCode` | As in §4, including the plaintext-ABORT rule. |

**Attachments.** `offerAttachment(manifest:payloadProvider:)` strips any value and sends the
offer; the caller must have passed ReauthGate first (Touch ID or master password). The provider
(`@Sendable () async throws -> SecretBytes`) runs only when the peer requests the value; the
session builds the payload from the offered manifest plus that value, sends it and wipes the
returned buffer. If the provider throws, the offer is withdrawn (DECLINE). The receiver sees
`attachmentOffered(ChatAttachmentOfferModel)` (kind, name, repository, environment; never a
value), then after `requestAttachment` gets `attachmentReceived(id, SharePackageModel)` with
`SecretBytes` values: the app runs `ShareImportPlanner` and `ShareImporter` exactly as for a
nearby share, re-encrypting into the vault, and wipes the package. `declineAttachment` sends
DECLINE.

**Timers** (`VaultClock`; separate from share):

| Phase | Timer |
|---|---|
| awaitingPeer | none for the responder; the initiator's handshake timer covers connecting |
| awaitingHello, awaitingReveal | handshake, 30 s |
| comparingCodes | SAS, 120 s |
| chatting | idle, 10 min (`Timeouts.chatIdle`), restarted by every TEXT and attachment frame in either direction; `timeout(.chatIdle)` |
| chatting | PING every 30 s (`Timeouts.chatKeepaliveInterval`); the tick after 2 unanswered PINGs (`Limits.chatMaxUnansweredPings`) aborts with `timeout(.keepalive)` |
| whole chat | no limit |

**Ephemerality and wiping.** The machine keeps no message history: each message exists only in
its event. `close()` (window closed, vault locked), every abort and every disconnect drop the
keys, every offer and value provider, cancel pending provider calls and zero any partial
payload buffer. Every decrypted frame body is zeroed once dispatched, and the payload buffer is
reserved at its announced size so chunks never leave a reallocated copy (the share handshake
also zeroes its decrypted bodies). Swift `String` copies of message text cannot be wiped
(SECURITY-MODEL.md residual risks); no message is logged or written to disk. Saving an
attachment is a share import: it records the package id, dates and the unverified sender name in
`imported_share_packages` (replay detection) and logs the changed-item count, as every import
does.

**VaultData and the window** (`VaultData/Chat/`, `App/Screens/NearbyChat/`).
`ChatRepository.makeConversation(role:transport:localName:clock:)` wraps one
`NearbyChatSession` in a `NearbyChatConversation`:
- *Offer:* `offerItem(_:senderName:appVersion:authorization:)` consumes a
  `ShareAuthorizationModel(.nearbySend)` and builds the manifest with the share builder's
  `.item(id)` selection (scope `secret`; an environment item is a partial environment, schema 2,
  §1.2). The value provider decrypts the item inside `VaultSession.read` only when the peer asks,
  and refuses (the offer is withdrawn) if the item was deleted, renamed, moved or changed kind
  since the offer, its stored value fingerprint (`value_fp`) differs from the one read when the
  offer was authorized, or the vault is locked.
- *Receive:* `.attachmentReceived` is forwarded with the manifest only; the value waits in the
  conversation until `previewAttachment(_:checkGitHub:)` moves it into a share import draft
  (`SharingRepository.apply` then plans it again inside the write transaction, exactly as for a
  file or a nearby share) or `discardAttachment` / `close()` / an abort / a disconnect wipes it.
- *Picker:* `ChatRepository.attachableItems()` lists live items that have a value (names only).
- *Window:* advertises with `advertisingChat(displayName:)` and browses with
  `NWNearbyBrowser(purpose: .chat)` only while it lists people, on the `local.` Bonjour domain
  only (link-local: infrastructure Wi-Fi or Ethernet and AWDL); this Mac is left out of the
  list by the instance name Bonjour actually registered (`registeredServiceNames`). Whoever
  presses "Chat" is the initiator, the other side's advertisement is the responder. On
  `incomingConnection` the window shows "Not visible" (the listener withdrew the
  advertisement). A responder connection that drops, stays silent or sends garbage before its
  HELLO re-advertises without limit; only a listener that fails without accepting anyone counts,
  and after three such failures in a row the window stops and offers "Try Again". A responder
  whose peer leaves after HELLO but before the code is shown goes back to the people list with
  no "ended" screen and no failed-handshake count. Every end of a chat wipes the transcript; a
  new chat is a new session and a new advertisement.

**Vectors** (`Fixtures/chat_kat.json`, same inputs as §4, both sides offering `maxVer` 1): C `bb69f4e4…4eb50c58`,
TH `b2ba2fab…90065cb4`, SAS **550 392**, the chat transcript over the share commitment
`360 242`, plus CONFIRM (both directions), TEXT "Hello from FX Vault" I→R seq 1, PING R→I seq 1
and CLOSE I→R seq 2. `crosscheck.py --write-chat` and `NearbyProtocolReference.swift` (its
`chat_` lines) produce them byte for byte; regenerating `nearby_kat.json` gives an identical file.

### 7.1 Chat version 2: whole repositories (v0.4.0)

Bryan's decisions (Q3): a whole repository's configuration can be sent in a chat; the receiver
imports it into a repository they choose or saves it as an encrypted `.fxvault` file; there is
no plaintext export from chat.

**Negotiation.** The chat now offers `maxVer` 2 in HELLO_I and HELLO_R
(`NearbyChatProtocol.maxVersion`; nearby share keeps 1). Both sides use
`version = min(maxVerI, maxVerR)`, and the transcript binds both offers and the result (§4
step 4), so a relay that lowers a version changes the commitment check and the code. A 0.2.x or
0.3.x Mac offers 1 and accepts a HELLO that offers 2 (it requires only `≥ minVersion`), so a
chat between 0.4.0 and an older Mac negotiates 1 and works exactly as before. The label prefix
(`fxvault/chat/v1/…`), the TXT record `v=1`, the frame layout (its version byte stays 1) and the
frame types are unchanged.

**What version 2 adds.** At a negotiated version ≥ 2
(`NearbyChatProtocol.configurationAttachmentsVersion`), ATTACHMENT_OFFER may carry a manifest of
scope `repository` (the repository level and every environment with its branch policy) or
`environment`: names and value states only, every item allowed with a value present or missing
(GitHub never returns secret values), validated as any share manifest. Below version 2 such an
offer aborts with `invalidPackage(scopeMismatch)` as in version 1, and the sender refuses to
make one (`ChatError.peerNeedsUpdate`) before anything is sent.

| Rule | One item | Configuration (version 2) |
|---|---|---|
| Offer scope | `secret`, one item with a value | `repository` or `environment` |
| Payload JSON | ≤ 512 KiB (`chatAttachmentBytes`) | ≤ 16 MiB (`chatConfigurationAttachmentBytes`, the nearby share limit) |
| Payload content | the offer with its value | the offer with its values (`payloadMismatch` otherwise) |
| Sender's provider | `ChatAttachmentValueProvider` → one value | `ChatConfigurationPayloadProvider` → the package |

Payload chunks never count toward the flood limit and restart the idle timer, as in version 1.
Open-offer and per-chat offer limits count both kinds together.

**Sender.** `offerConfiguration(manifest:payloadProvider:)` strips values and sends the offer;
the provider runs only after ATTACHMENT_REQUEST and must return a package whose manifest equals
the offer, or the offer is withdrawn (DECLINE); the session wipes the values once sent. VaultData
(`NearbyChatConversation.offerRepository`) checks the negotiated version before it consumes the
`.nearbySend` authorization, builds the manifest with the share builder's `.repository(id)`
selection and records every item's stored `value_fp`. On request it rebuilds the package with
values, gives it the offer's entry ids (`ShareRepositoryModel.withEntryIDs(of:)`: entry ids are
random per build, so the same shape takes the offered ids and another shape is refused) and
sends it only if the fingerprints, the shape and the value states still equal the offer.

**Receiver.** The card shows the repository's `owner/name` and counts
(`ChatConfigurationSummaryModel`: environments, secrets, variables, items without a value).
**Import Into…** requests the payload, then lists the receiver's repositories;
`previewAttachment(_:into:checkGitHub:)` plans the package as if it were for the chosen
repository (its owner, name and GitHub id are taken from the receiver's vault row, so the §9.5
GitHub id check holds for that repository) with the same planner, preview, replay rules and
`SharingRepository.apply` as §5–§6. Environments the target lacks are created; every change is
pending for the next Sync. **Save as File…** (`saveAttachment(_:to:authorization:)`, after
`.fileExport` re-authentication) seals the received package unchanged (sender's name and package
id kept) into a `.fxvault` file under a fresh passphrase (§2–§3). The package stays in the
conversation until an import preview takes it (applied, or wiped on Cancel, as for one item) or
the chat ends; closing the repository choice before Continue leaves it there. A whole repository
is a schema 1 package (§1.1), so the file opens in every FX Vault version.

## 8. Compatibility between versions (v0.2.0)

| Feature | 0.1.x → 0.2.0 | 0.2.0 → 0.1.x |
|---|---|---|
| `.fxvault` file, schema v1 (whole repository, whole environments, repository-level items, a single repository-level item) | Imports unchanged | Imports |
| `.fxvault` file, schema v2 (any partly checked environment, including a single environment-level item) | n/a | Rejected: "Wrong passphrase or damaged file" (§1.1) |
| Nearby share, shared Wi-Fi network | Works (nearby protocol v1 unchanged, §4; the MANIFEST follows the file rules above) | Works for v1 packages; a v2 MANIFEST aborts on the 0.1.x side |
| Nearby share, no shared network (AWDL) | Not found: 0.1.x neither advertises nor browses over peer-to-peer Wi-Fi | Not found |
| Nearby Chat | 0.1.x has no chat and never browses `_fxvault-chat._tcp` | n/a |

Since v0.4.0 (§7.1):

| Chat feature | 0.4.0 with 0.4.0 | 0.4.0 with 0.2.x or 0.3.x |
|---|---|---|
| Messages, one secret or variable | Version 2 | Version 1, unchanged |
| A whole repository | Sent as one card; Import Into… or Save as File… | Not offered: the Whole Repository tab says the other Mac needs FX Vault 0.4 or later; nothing is sent |
| A `.fxvault` file saved from a received repository | Imports | Imports (schema 1) |

- **Versioning.** Nearby share (protocol v1, labels `fxvault/nearby/v1/…`) and chat
  (`fxvault-chat/v1`, labels `fxvault/chat/v1/…`) are fixed, as are the TXT record `v=1` and
  the frame types. A later revision raises `maxVer` in HELLO (bound into the transcript, §4
  step 4), as chat did in v0.4.0 (version 2, §7.1); a change that cannot be negotiated gets a
  new label prefix, so the commitment check fails cleanly, as it does between share and chat.
  `schemaVersion` changes follow the lowest-version rule in §1.1.
- **Chat attachments** are share manifests and payloads of scope `secret`, so they follow the
  schema rules of §1: a repository-level item is v1, an environment-level item is v2 (partial
  environment). Both ends of a chat are 0.2.0 or later, so both are always readable. A whole
  repository (version 2 chats only) is schema 1.
- **Mixed fleets.** Until every Mac runs 0.2.0, share whole environments (v1) with 0.1.x users,
  and use a shared network for nearby sharing with them.

Since v0.7.0 (§1.3, §10.8):

| Feature | 0.7.0 with 0.7.0 | 0.7.0 with 0.6 or older |
|---|---|---|
| A folder in Nearby Chat | Chat version 4: one card; Save as Folder, Import Into…, Save as File… | Not offered: the Folder tab says the other Mac needs FX Vault 0.7 or later; nothing is sent |
| A `.fxvault` file of a folder (schema 3) | Saved as a folder or imported into a scope | Rejected: "Wrong passphrase or damaged file" |

## 10. Teammates: `fxvault-team/v1` (v0.5.0)

Implemented in `Packages/FXVaultKit/Sources/SharingKit/Team`. Known-answer vectors:
`Tests/SharingKitTests/Fixtures/team_kat.json`, generated by `Fixtures/kat/crosscheck.py
--write-team` (RFC 7748, RFC 5869, RFC 8032; its Ed25519 signatures are deterministic, CryptoKit
signs with randomness, so Swift verifies them: `TeamKATTests`).

### 10.1 Purposes and services

| Purpose | Bonjour type | Labels | Advertised under |
|---|---|---|---|
| `.pair` (Add Teammate) | `_fxvault-pair._tcp` | `fxvault/pair/v1/…` | the display name, only while the sheet is open |
| `.team` (presence) | `_fxvault-team._tcp` | `fxvault/team/v1/…` | the pseudonym, while the vault is unlocked and visibility is not Nobody |

Both use the nearby transport (§4: TCP, 4-byte length framing, LAN and AWDL, `local.` only,
TXT `v=1`) and the encrypted frame layout (§4 Transfer). Byte strings below: `LP(x) = u32be(len) ‖ x`.

### 10.2 Device identity and cards

- Keys: Ed25519 (signing), X25519 (agreement), a 32-byte announce key.
- `deviceID = SHA256(LP("fxvault/team/v1/device-id") ‖ LP(signPK) ‖ LP(agreePK))[0..<16]`.
- Card: `0x01 ‖ deviceID(16) ‖ signPK(32) ‖ agreePK(32) ‖ announceKey(32) ‖ u16 ‖ login ‖ u16 ‖
  displayName ‖ u16 ‖ macName` (each string ≤ 63 bytes, sanitized). A decoder rejects a card whose
  id does not derive from its keys.

### 10.3 Pairing

The §4 handshake (commit-reveal, the 6-digit code, CONFIRM) with the pair labels, then each side
sends `CARD (0x40) = u16 len ‖ card ‖ Ed25519(LP("fxvault/pair/v1/card") ‖ role ‖ LP(TH) ‖ LP(card))`
(`role` = `I` or `R`). The receiver verifies the signature with the card's key and the role of its
peer, refuses its own device id, then both send CLOSE.

### 10.4 Pseudonyms

`pseudonym(window) = hex(HMAC-SHA256(announceKey, LP("fxvault/team/v1/announce") ‖ u64be(window))[0..<16])`
with `window = ⌊unix time / 900⌋`. The advertiser re-registers at every window change; a teammate
matches the current window and one on each side.

### 10.5 Presence connections

The initiator's first frame is the plaintext preamble `0x50 ‖ 0x01 ‖ service` (`0x01` team,
`0x02` chat). `0x02` continues as a nearby chat (§7, chat version 3, §10.7). `0x01` runs the
paired handshake:

1. I → R: `HELLO_I (0x51) = ver ‖ ephPK_I(32) ‖ n_I(32)`. R → I: `HELLO_R (0x52) = ver ‖ ephPK_R ‖ n_R`.
2. `TH = SHA256(LP("fxvault/team/v1/transcript") ‖ ver ‖ LP(ephPK_I) ‖ LP(n_I) ‖ LP(ephPK_R) ‖ LP(n_R))`;
   direction keys from `X25519(eph_I, eph_R)` salted with TH (`…/key/i2r`, `…/key/r2i`).
3. I → R (encrypted): `AUTH_I (0x53) = deviceID_I ‖ Ed25519(LP("fxvault/team/v1/auth-i") ‖ LP(TH) ‖
   LP(deviceID_I) ‖ LP(deviceID_R))`. R checks the device is a teammate, that `deviceID_R` is its
   own, and the signature; otherwise it aborts without revealing its identity.
4. R → I: `AUTH_R (0x54) = deviceID_R ‖ Ed25519(LP("fxvault/team/v1/auth-r") ‖ LP(TH) ‖ LP(deviceID_I) ‖
   LP(deviceID_R))`. I checks it is the teammate it meant.
5. Requests, in order: `PING (0x60)` → `PONG (0x61)`; `CARD_UPDATE (0x62) = card` (same keys, new
   announce key) → `CARD_UPDATED (0x63)`. Then CLOSE. The session must end within 30 s.

### 10.6 Limits

Presence listener: 20 connections a minute; preamble within 30 s. Pings: one per teammate every
10 s (sender), five per teammate per minute (receiver).

### 10.7 Chat version 3

`NearbyChatProtocol.maxVersion` is 3. At a negotiated version of 3, while comparing codes,
`TEAMMATE_IDENT (0x25) = deviceID ‖ Ed25519(LP("fxvault/team/v1/chat-ident") ‖ role ‖ LP(TH_chat))`.
The initiator sends it right after REVEAL when the chat was opened from a teammate's bubble; the
responder verifies it against its teammates, answers with its own and confirms the code; the
initiator confirms once it verified the expected teammate. A 0.4 or older peer negotiates 2 or 1
and the people compare the code.

### 10.8 Chat version 4 (v0.7.0)

`NearbyChatProtocol.maxVersion` is 4. Frames and labels are unchanged. At a negotiated version of
4 an attachment may be a folder package (§1.3, scope `folder`), offered and fetched like a whole
repository (`ATTACHMENT_OFFER` with the manifest, `ATTACHMENT_REQUEST`, chunked
`ATTACHMENT_PAYLOAD` up to the configuration limit, 16 MiB). The sender refuses to offer a folder
to a peer below 4 (`ChatError.peerNeedsUpdate`) before any authorization is used; a receiver below
4 that gets one aborts with `invalidPackage(scopeMismatch(folder))`. The receiver's card shows the
folder's name and counts; values travel only after Save…

## 11. Shared spaces: `fxvault-space/v1` (v0.6.0, experimental)

Implemented in `Packages/FXVaultKit/Sources/SharingKit/Space` (log, crypto, marker, gate) and
`SharingKit/Team` (the spaces service); stored by `VaultData/Spaces/SpaceRepository`. A space is
one scope (the repository level or one environment) of one GitHub repository shared by member
devices, which are paired teammates (§10). Byte strings: `LP(x) = u32be(len) ‖ x`; labels are
`fxvault/space/v1/…`.

### 11.1 Versions

A space is a linear, signed log. Every version is a **full snapshot** of the scope as GitHub holds
it after that version (or, for a members version, an empty one with the new member list).

- Header: `format(1) ‖ spaceID(16) ‖ u64 version ‖ parentHash(32) ‖ u32 epoch ‖ u8 kind ‖
  author deviceID(16) ‖ i64 createdAt (unix ms)`. Kinds: 1 genesis, 2 publish, 3 members.
- Keyring (genesis and members only, empty otherwise): `format ‖ u8 hasBinding ‖ [LP(githubRepoID)
  ‖ LP(owner) ‖ LP(name) ‖ u8 hasEnv ‖ [LP(environment)]] ‖ u16 members ‖ (deviceID ‖ signPK ‖
  agreePK ‖ u16+login ‖ u16+displayName ‖ u16+macName)* ‖ u16 wraps ‖ (deviceID ‖ u32 epoch ‖
  LP(enc) ‖ LP(ciphertext))*`. A member whose id does not derive from its keys is refused.
- Payload plaintext: `format ‖ LP(reason) ‖ u32 count ‖ (u8 kind ‖ LP(name) ‖ u8 hasValue ‖
  [LP(value)] ‖ u8 hasDate ‖ [i64 GitHub updatedAt, ms])*`, sorted by kind then name.
- Payload ciphertext: AES-256-GCM (combined) under `HKDF-SHA256(epochKey, salt: spaceID, info:
  …/payload)`, AAD `SHA256(LP(header) ‖ LP(keyring))`.
- `hash = SHA256(LP(…/version) ‖ LP(header) ‖ LP(keyring) ‖ LP(payloadCiphertext))`; the author
  signs `LP(…/signature) ‖ LP(hash)` with its Ed25519 key.
- Wire form: `LP(header) ‖ LP(keyring) ‖ LP(payloadCiphertext) ‖ signature(64)`, at most 16 MiB.

Rules (`SpaceLog`): version 1 is genesis (parent 32 zero bytes, epoch 1, a binding, its author a
member, an epoch-1 wrap for every member). Every later version is `head + 1`, its parent is the
head's hash, and its author was a member before it. A publish keeps the epoch and has no
keyring. A members version lists every member after it; a member's keys never change. Removing
anyone moves to `epoch + 1` with the new key wrapped for every remaining member; only adding keeps
the epoch and wraps every epoch key so far for each new member (they get the whole history).

Epoch keys are random 32-byte keys, wrapped per device with HPKE (RFC 9180, X25519 / SHA-256 /
ChaCha20-Poly1305), info `LP(…/wrap) ‖ spaceID ‖ u32 epoch ‖ deviceID`. The short fingerprint of a
value shown in History, the same on every member's Mac: `HMAC-SHA256(HKDF(epoch-1 key, salt:
spaceID, info: …/fingerprint), u8 kind ‖ LP(name) ‖ LP(value))[0..<4]` in hex.

### 11.2 Marker

`FXVAULT_SPACE`, a variable in the scope it describes (≤ 512 bytes), sorted-key JSON:
`{"at","by","dev","f":1,"head","sig","space","state","v"}`. `published`: `v` is the head version,
`head` its hash. `publishing`: `v` is the version being pushed, `head` the hash of its parent.
`sig` (base64) signs `LP(…/marker) ‖ spaceID ‖ u64 v ‖ u8 state (1 publishing, 2 published) ‖
LP(head) ‖ LP(dev) ‖ LP(at) ‖ LP(by)`. `at` is for display only. The name is reserved: user items
cannot use it, and every variable listing splits it off (§API B8/B9).

The gate (`SpaceGate.decide`) compares the marker with this Mac's verified head: no marker or the
head itself → clear; this Mac ahead (an unfinished publish of its own) → ahead; a higher version
→ behind; another member's `publishing` claim on the head → publishing (stale after 15 minutes,
when it may be taken over after a confirmation); the same number with another hash → forked; an
unreadable marker or one not signed by a member → invalid; this device no longer a member → not a
member. Only clear and ahead let a push run.

### 11.3 Publishing (Sync)

For every shared scope a run writes: preflight lists the scope and decides the gate; before the
scope's first write the executor writes a `publishing` marker for `head + 1` and re-reads it (a
different marker stops the scope); after the repository's steps it records the version of what
GitHub now holds (none when nothing changed), writes the `published` marker and re-reads it. The
claim is recorded locally until that re-read confirms it; launch reconciliation finishes a claim
a crash or a failed write left open.

### 11.4 Spaces service (Mac to Mac)

Preamble service `0x03`, the paired handshake of §10.5, then only these encrypted messages:

| Type | Direction | Body |
|---|---|---|
| `SPACE_HEADS (0x64)` | I → R | `u16 count ‖ (spaceID ‖ u64 version ‖ hash)*`: I's heads of the spaces it shares with R |
| `SPACE_HEADS_REPLY (0x65)` | R → I | the same, R's heads of the spaces it shares with I |
| `SPACE_FETCH (0x66)` | I → R | `spaceID ‖ u64 version` |
| `SPACE_VERSION (0x67)` | R → I | `u32 length` (0: not sent: unknown version, or I is not a member) |
| `SPACE_CHUNK (0x68)` | R → I | the next bytes of the version (≤ one frame each) |

The session is pull-only: I fetches every version it lacks, one at a time; for a space it does not
have it fetches the whole log (≤ 64 MiB) and stores it only once the whole chain verifies and it is
a member at its head. Any member relays any version (signatures and hashes make relaying safe). A
responder whose peer's heads are ahead pulls back in its own session. The team service (`0x01`)
refuses space messages and the spaces service refuses PING and CARD_UPDATE. A spaces session must
end within 2 minutes; at most 512 heads per frame.

### 11.5 Outside the local network (Q4)

A teammate turned on for remote sync on both Macs can reach the other's spaces service at a typed
`host:port` (for example a Tailscale name). The listener (TCP, never advertised) routes only
preamble `0x03`, answers only the teammates turned on for it, and after 5 failed sessions in 10
minutes stays closed for 10 minutes. The initiator connects only to the address typed for that
teammate and aborts unless the peer proves that teammate's key (§10.5 AUTH_R).
