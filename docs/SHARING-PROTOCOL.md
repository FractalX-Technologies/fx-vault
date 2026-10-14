# FX Vault - Sharing formats and protocol

Implemented in `Packages/FXVaultKit/Sources/SharingKit`. This document records the wire formats
as built (plan §9 plus the decisions made during M6 implementation). Known-answer vectors are
pinned in `Tests/SharingKitTests/Fixtures/nearby_kat.json`; the independent generators
(`Fixtures/kat/crosscheck.py`, Python `cryptography`; `Fixtures/kat/NearbyProtocolReference.swift`)
produce byte-identical output.

## 1. Payload: `SharePackageModel` (schema 1)

JSON, keys sorted, dates ISO-8601 UTC with `Z`. `value` and `githubUpdatedAt` are always present
(explicit `null` when absent).

```json
{ "schema": "io.fractalx.fxvault.share", "schemaVersion": 1,
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
                                                 "patterns": [{"name": "release/*", "type": "branch | tag"}]},
                      "secrets": [ ... ], "variables": [ ... ]}] } }
```

- **Entry ids** (`ShareEntryID`, a UUID) are on every item and environment, in one id space.
  They exist so the nearby DECISION can name what the receiver accepted.
- **Manifest** = the same document with every `value` set to null (`valueState` kept). Value
  hashes are never included.
- **`secret` scope** means exactly one item (secret or variable), at repository or environment
  level.

`SharePackageValidator` (modes `.manifest` and `.payload`) rejects, among others: a schema or
version other than the above; producer or sender fields that are not already sanitized; a host
other than `github.com`; invalid owner or repository names (`.`, `..`, `*.git`); a `githubRepoId`
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
random service instance name per session; TXT holds only `v=1`. TCP with `acceptLocalOnly`,
cellular prohibited, `includePeerToPeer = false` (no AWDL: both Macs must share a network). The
listener accepts only the first connection (a second is `secondPeer`). Framing: u32 BE length
prefix (`NearbyLengthFramer`). Local Network denial is reported as
`NearbyTransportFailure.localNetworkDenied`.

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
| 9 | I→R PAYLOAD_CHUNK 0x13 … PAYLOAD_END 0x14 | Chunks carry the JSON of the package filtered to the accepted ids; END is `u64 BE length ‖ SHA-256(payload)`. A mismatch aborts (`payloadMismatch`). |
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
- **Environments:** missing ones are created (pending unless GitHub already lists them). A
  different branch policy is its own row, defaulting to keep mine. Widening (anything → all,
  custom → protected, or a new pattern containing `*`, `?` or `[`) needs a second confirmation.
