"""Independent Python cross-check of the FX Vault nearby v1, chat v1 and .fxvault v1 vectors.

Revised for the M6 transcript (tasks/todo.md §9.4): C binds maxVerI and suiteI; TH binds
maxVerI, maxVerR, ver, suiteI, suiteR, C, both keys, both nonces and both names.

v0.2.0 adds fxvault-chat/v1: the same handshake and frame layout with every label under the
prefix "fxvault/chat/v1" instead of "fxvault/nearby/v1" (domain separation from share), plus
chat frame types (TEXT 0x20, PING 0x30, CLOSE 0x7E).

X25519 and HKDF are implemented here from RFC 7748 / RFC 5869 with the standard library, and
re-checked against the `cryptography` package, which also provides AES-GCM.

Usage (from a venv with `cryptography` installed):
  python3 crosscheck.py --lines              # key=value lines, comparable with the Swift reference
  python3 crosscheck.py --write nearby_kat.json
  python3 crosscheck.py --chat-lines         # chat vectors as key=value lines
  python3 crosscheck.py --write-chat chat_kat.json
  python3 crosscheck.py --team-lines         # teammate vectors (v0.5.0) as key=value lines
  python3 crosscheck.py --write-team team_kat.json

v0.5.0 adds fxvault-team/v1 (pairing labels "fxvault/pair/v1", presence and paired-handshake
labels "fxvault/team/v1"): device ids, cards, pseudonyms, the paired handshake's transcript,
keys and AUTH messages, and Ed25519 signatures (RFC 8032, deterministic here; CryptoKit signs
with randomness, so Swift verifies these signatures instead of reproducing them).

v0.6.0 adds fxvault-space/v1 (labels "fxvault/space/v1"): a two-version log (Ana's genesis,
Ben's publish) with its headers, keyrings, payload ciphertexts (HKDF-SHA256 + AES-256-GCM with
fixed nonces), hashes and Ed25519 signatures; HPKE wraps of the epoch key (RFC 9180, X25519 /
HKDF-SHA256 / ChaCha20-Poly1305, random ephemerals: Swift opens them); a signed marker in its
canonical JSON; and a value fingerprint.
  python3 crosscheck.py --space-lines        # shared space vectors (v0.6.0) as key=value lines
  python3 crosscheck.py --write-space space_kat.json
"""
import hashlib
import hmac
import json
import struct
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives import hpke
import base64
import uuid

P = 2**255 - 19
A24 = 121665

SHARE_PREFIX = b'fxvault/nearby/v1'
CHAT_PREFIX = b'fxvault/chat/v1'
PAIR_PREFIX = b'fxvault/pair/v1'
TEAM_PREFIX = b'fxvault/team/v1'


def clamp(k):
    k = bytearray(k)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    return int.from_bytes(k, 'little')


def x25519(k, u):
    k = clamp(k)
    x1 = int.from_bytes(u, 'little') & ((1 << 255) - 1)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in reversed(range(255)):
        kt = (k >> t) & 1
        swap ^= kt
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = kt
        A = (x2 + z2) % P; AA = A * A % P; B = (x2 - z2) % P; BB = B * B % P; E = (AA - BB) % P
        C = (x3 + z3) % P; Dd = (x3 - z3) % P; DA = Dd * A % P; CB = C * B % P
        x3 = (DA + CB) ** 2 % P; z3 = x1 * (DA - CB) ** 2 % P; x2 = AA * BB % P; z2 = E * (AA + A24 * E) % P
    if swap:
        x2, x3, z2, z3 = x3, x2, z3, z2
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, 'little')


def lp(d):
    return struct.pack('>I', len(d)) + d


def hkdf(ikm, salt, info, n):
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, t, i = b'', b'', 1
    while len(out) < n:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        out += t
        i += 1
    return out[:n]


def commitment(max_ver_i, suite_i, pk_i, n_i, prefix=SHARE_PREFIX):
    return hashlib.sha256(lp(prefix + b'/commit') + bytes([max_ver_i, suite_i]) + lp(pk_i) + lp(n_i)).digest()


def transcript(max_ver_i, max_ver_r, ver, suite_i, suite_r, c, pk_i, n_i, name_i, pk_r, n_r, name_r,
               prefix=SHARE_PREFIX):
    m = lp(prefix + b'/transcript') + bytes([max_ver_i, max_ver_r, ver, suite_i, suite_r])
    m += lp(c) + lp(pk_i) + lp(n_i) + lp(name_i.encode()) + lp(pk_r) + lp(n_r) + lp(name_r.encode())
    return hashlib.sha256(m).digest()


def sas(ss, th, prefix=SHARE_PREFIX):
    value = int.from_bytes(hkdf(ss, th, prefix + b'/sas', 8), 'big') % 1000000
    digits = f'{value:06d}'
    return value, digits[:3] + ' ' + digits[3:]


def seal_frame(key, frame_type, seq, plaintext):
    header = bytes([1, frame_type]) + struct.pack('>Q', seq)
    nonce = bytes(4) + struct.pack('>Q', seq)
    return header + AESGCM(key).encrypt(nonce, plaintext, header)


def fxvault_header(ops, mem_kib, salt, nonce):
    h = bytes([0x46, 0x58, 0x56, 0x41, 0x55, 0x4C, 0x54, 0x1A])
    h += struct.pack('>HH', 1, 64) + bytes([1, 1]) + struct.pack('>II', ops, mem_kib) + bytes([1, 0])
    h += salt + nonce
    return h + bytes(64 - len(h))


def vectors():
    sk_i = bytes(range(0x00, 0x20)); sk_r = bytes(range(0x20, 0x40))
    n_i = bytes(range(0x40, 0x60)); n_r = bytes(range(0x60, 0x80))
    name_i, name_r = "Alice's Mac", "Bob's Mac"
    base = (9).to_bytes(32, 'little')
    pk_i = x25519(sk_i, base); pk_r = x25519(sk_r, base)
    raw = serialization.Encoding.Raw, serialization.PublicFormat.Raw
    assert pk_i == X25519PrivateKey.from_private_bytes(sk_i).public_key().public_bytes(*raw)
    assert pk_r == X25519PrivateKey.from_private_bytes(sk_r).public_key().public_bytes(*raw)
    ss = x25519(sk_i, pk_r)
    assert ss == x25519(sk_r, pk_i)
    assert ss == X25519PrivateKey.from_private_bytes(sk_i).exchange(X25519PublicKey.from_public_bytes(pk_r))

    c = commitment(1, 1, pk_i, n_i)
    th = transcript(1, 1, 1, 1, 1, c, pk_i, n_i, name_i, pk_r, n_r, name_r)
    sas_value, sas_text = sas(ss, th)
    k_i2r = hkdf(ss, th, b'fxvault/nearby/v1/key/i2r', 32)
    k_r2i = hkdf(ss, th, b'fxvault/nearby/v1/key/r2i', 32)
    _, sas_altered = sas(ss, transcript(1, 1, 1, 1, 1, c, pk_i, n_i, name_i, pk_r, n_r, name_r + ' '))
    th_higher_r = transcript(1, 2, 1, 1, 1, c, pk_i, n_i, name_i, pk_r, n_r, name_r)

    salt = bytes(range(0x80, 0x90)); file_nonce = bytes(range(0x90, 0x9c))
    header = fxvault_header(3, 65536, salt, file_nonce)
    payload = b'{"schema":"fxvault.share/1"}'
    ct_tag = AESGCM(bytes([0x42]) * 32).encrypt(file_nonce, payload, header)
    assert AESGCM(bytes([0x42]) * 32).decrypt(file_nonce, ct_tag, header) == payload

    outputs = {
        'C': c.hex(),
        'CONFIRM_i2r_seq0': seal_frame(k_i2r, 0x10, 0, b'\x01').hex(),
        'CONFIRM_r2i_seq0': seal_frame(k_r2i, 0x10, 0, b'\x01').hex(),
        'SAS': sas_text,
        'SAS_altered_nameR': sas_altered,
        'SAS_value': str(sas_value),
        'TH': th.hex(),
        'TH_maxVerR_2': th_higher_r.hex(),
        'fxvault_ciphertext_and_tag': ct_tag.hex(),
        'fxvault_file_length': str(len(header) + len(ct_tag)),
        'fxvault_header': header.hex(),
        'k_i2r': k_i2r.hex(),
        'k_r2i': k_r2i.hex(),
        'pkI': pk_i.hex(),
        'pkR': pk_r.hex(),
        'shared_secret': ss.hex(),
    }
    inputs = {
        'skI': sk_i.hex(), 'skR': sk_r.hex(), 'nI': n_i.hex(), 'nR': n_r.hex(),
        'nameI': name_i, 'nameR': name_r, 'nameR_altered': name_r + ' ',
        'maxVerI': 1, 'maxVerR': 1, 'ver': 1, 'suiteI': 1, 'suiteR': 1,
        'confirm_plaintext': '01',
        'fxvault_key': (bytes([0x42]) * 32).hex(), 'fxvault_opsLimit': 3, 'fxvault_memLimitKiB': 65536,
        'fxvault_salt': salt.hex(), 'fxvault_nonce': file_nonce.hex(), 'fxvault_payload_utf8': payload.decode(),
    }
    return inputs, outputs


CHAT_TEXT = 'Hello from FX Vault'


def chat_vectors():
    """fxvault-chat/v1 vectors: the share inputs (keys, nonces, names) with the chat labels."""
    sk_i = bytes(range(0x00, 0x20)); sk_r = bytes(range(0x20, 0x40))
    n_i = bytes(range(0x40, 0x60)); n_r = bytes(range(0x60, 0x80))
    name_i, name_r = "Alice's Mac", "Bob's Mac"
    base = (9).to_bytes(32, 'little')
    pk_i = x25519(sk_i, base); pk_r = x25519(sk_r, base)
    ss = x25519(sk_i, pk_r)
    assert ss == X25519PrivateKey.from_private_bytes(sk_r).exchange(X25519PublicKey.from_public_bytes(pk_i))

    c = commitment(1, 1, pk_i, n_i, CHAT_PREFIX)
    assert c != commitment(1, 1, pk_i, n_i)
    th = transcript(1, 1, 1, 1, 1, c, pk_i, n_i, name_i, pk_r, n_r, name_r, CHAT_PREFIX)
    sas_value, sas_text = sas(ss, th, CHAT_PREFIX)
    k_i2r = hkdf(ss, th, CHAT_PREFIX + b'/key/i2r', 32)
    k_r2i = hkdf(ss, th, CHAT_PREFIX + b'/key/r2i', 32)
    # The share commitment checked with the chat label (purpose confusion) never matches, and the
    # chat transcript over the share commitment gives yet another code.
    th_share_commitment = transcript(1, 1, 1, 1, 1, commitment(1, 1, pk_i, n_i), pk_i, n_i, name_i,
                                     pk_r, n_r, name_r, CHAT_PREFIX)
    _, sas_share_commitment = sas(ss, th_share_commitment, CHAT_PREFIX)

    outputs = {
        'C': c.hex(),
        'CLOSE_i2r_seq2': seal_frame(k_i2r, 0x7E, 2, b'').hex(),
        'CONFIRM_i2r_seq0': seal_frame(k_i2r, 0x10, 0, b'\x01').hex(),
        'CONFIRM_r2i_seq0': seal_frame(k_r2i, 0x10, 0, b'\x01').hex(),
        'PING_r2i_seq1': seal_frame(k_r2i, 0x30, 1, b'').hex(),
        'SAS': sas_text,
        'SAS_value': str(sas_value),
        'SAS_with_share_commitment': sas_share_commitment,
        'TEXT_i2r_seq1': seal_frame(k_i2r, 0x20, 1, CHAT_TEXT.encode()).hex(),
        'TH': th.hex(),
        'k_i2r': k_i2r.hex(),
        'k_r2i': k_r2i.hex(),
        'pkI': pk_i.hex(),
        'pkR': pk_r.hex(),
        'shared_secret': ss.hex(),
    }
    inputs = {
        'skI': sk_i.hex(), 'skR': sk_r.hex(), 'nI': n_i.hex(), 'nR': n_r.hex(),
        'nameI': name_i, 'nameR': name_r,
        'maxVerI': 1, 'maxVerR': 1, 'ver': 1, 'suiteI': 1, 'suiteR': 1,
        'labelPrefix': CHAT_PREFIX.decode(),
        'text_utf8': CHAT_TEXT,
    }
    return inputs, outputs


def ed25519_public(seed):
    return Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def device_id(sign_pk, agree_pk):
    return hashlib.sha256(lp(TEAM_PREFIX + b'/device-id') + lp(sign_pk) + lp(agree_pk)).digest()[:16]


def card(sign_pk, agree_pk, announce, login, display, mac):
    data = bytes([1]) + device_id(sign_pk, agree_pk) + sign_pk + agree_pk + announce
    for text in (login, display, mac):
        raw = text.encode()
        data += struct.pack('>H', len(raw)) + raw
    return data


def pseudonym(announce, window):
    return hmac.new(announce, lp(TEAM_PREFIX + b'/announce') + struct.pack('>Q', window), hashlib.sha256).digest()[:16].hex()


TEAM_WINDOW = 1988888


def team_vectors():
    """fxvault-team/v1 vectors (v0.5.0): two devices, Ana (initiator) and Ben (responder)."""
    base = (9).to_bytes(32, 'little')
    ana_seed, ana_agree, ana_announce = bytes(range(0x80, 0xA0)), bytes(range(0xA0, 0xC0)), bytes(range(0xC0, 0xE0))
    ben_seed, ben_agree, ben_announce = bytes(range(0x10, 0x30)), bytes(range(0x30, 0x50)), bytes(range(0x50, 0x70))
    ana_sign_pk, ben_sign_pk = ed25519_public(ana_seed), ed25519_public(ben_seed)
    ana_agree_pk, ben_agree_pk = x25519(ana_agree, base), x25519(ben_agree, base)
    ana_id, ben_id = device_id(ana_sign_pk, ana_agree_pk), device_id(ben_sign_pk, ben_agree_pk)
    ana_card = card(ana_sign_pk, ana_agree_pk, ana_announce, 'user-a', 'Ana', "Ana's Mac")

    # The paired handshake: the chat vectors' ephemerals and nonces.
    eph_i, eph_r = bytes(range(0x00, 0x20)), bytes(range(0x20, 0x40))
    n_i, n_r = bytes(range(0x40, 0x60)), bytes(range(0x60, 0x80))
    eph_pk_i, eph_pk_r = x25519(eph_i, base), x25519(eph_r, base)
    ss = x25519(eph_i, eph_pk_r)
    assert ss == X25519PrivateKey.from_private_bytes(eph_r).exchange(X25519PublicKey.from_public_bytes(eph_pk_i))
    th = hashlib.sha256(lp(TEAM_PREFIX + b'/transcript') + bytes([1]) + lp(eph_pk_i) + lp(n_i)
                        + lp(eph_pk_r) + lp(n_r)).digest()
    k_i2r = hkdf(ss, th, TEAM_PREFIX + b'/key/i2r', 32)
    k_r2i = hkdf(ss, th, TEAM_PREFIX + b'/key/r2i', 32)
    auth_i_message = lp(TEAM_PREFIX + b'/auth-i') + lp(th) + lp(ana_id) + lp(ben_id)
    auth_r_message = lp(TEAM_PREFIX + b'/auth-r') + lp(th) + lp(ana_id) + lp(ben_id)
    auth_i_signature = Ed25519PrivateKey.from_private_bytes(ana_seed).sign(auth_i_message)
    auth_r_signature = Ed25519PrivateKey.from_private_bytes(ben_seed).sign(auth_r_message)
    hello_i = bytes([0x51, 1]) + eph_pk_i + n_i

    # Pairing: the nearby handshake with the pair labels, then Ana's signed card.
    c_pair = commitment(1, 1, eph_pk_i, n_i, PAIR_PREFIX)
    th_pair = transcript(1, 1, 1, 1, 1, c_pair, eph_pk_i, n_i, "Ana's Mac", eph_pk_r, n_r, "Ben's Mac", PAIR_PREFIX)
    card_message_i = lp(PAIR_PREFIX + b'/card') + b'I' + lp(th_pair) + lp(ana_card)
    card_signature_i = Ed25519PrivateKey.from_private_bytes(ana_seed).sign(card_message_i)
    chat_ident_message_i = lp(TEAM_PREFIX + b'/chat-ident') + b'I' + lp(th)

    outputs = {
        'AUTH_I_i2r_seq0': seal_frame(k_i2r, 0x53, 0, ana_id + auth_i_signature).hex(),
        'C_pair': c_pair.hex(),
        'HELLO_I': hello_i.hex(),
        'PING_i2r_seq1': seal_frame(k_i2r, 0x60, 1, b'').hex(),
        'PREAMBLE_chat': bytes([0x50, 1, 2]).hex(),
        'PREAMBLE_team': bytes([0x50, 1, 1]).hex(),
        'TH': th.hex(),
        'TH_pair': th_pair.hex(),
        'ana_agreement_pk': ana_agree_pk.hex(),
        'ana_card': ana_card.hex(),
        'ana_device_id': ana_id.hex(),
        'ana_pseudonym': pseudonym(ana_announce, TEAM_WINDOW),
        'ana_pseudonym_next': pseudonym(ana_announce, TEAM_WINDOW + 1),
        'ana_signing_pk': ana_sign_pk.hex(),
        'auth_i_message': auth_i_message.hex(),
        'auth_i_signature': auth_i_signature.hex(),
        'auth_r_message': auth_r_message.hex(),
        'auth_r_signature': auth_r_signature.hex(),
        'ben_device_id': ben_id.hex(),
        'ben_signing_pk': ben_sign_pk.hex(),
        'card_message_i': card_message_i.hex(),
        'card_signature_i': card_signature_i.hex(),
        'chat_ident_message_i': chat_ident_message_i.hex(),
        'ephPkI': eph_pk_i.hex(),
        'ephPkR': eph_pk_r.hex(),
        'k_i2r': k_i2r.hex(),
        'k_r2i': k_r2i.hex(),
        'shared_secret': ss.hex(),
    }
    inputs = {
        'anaSigningSeed': ana_seed.hex(), 'anaAgreementKey': ana_agree.hex(), 'anaAnnounceKey': ana_announce.hex(),
        'benSigningSeed': ben_seed.hex(), 'benAgreementKey': ben_agree.hex(), 'benAnnounceKey': ben_announce.hex(),
        'anaLogin': 'user-a', 'anaDisplayName': 'Ana', 'anaMacName': "Ana's Mac",
        'ephI': eph_i.hex(), 'ephR': eph_r.hex(), 'nI': n_i.hex(), 'nR': n_r.hex(),
        'window': TEAM_WINDOW,
        'pairLabelPrefix': PAIR_PREFIX.decode(), 'teamLabelPrefix': TEAM_PREFIX.decode(),
    }
    return inputs, outputs


SPACE_PREFIX = b'fxvault/space/v1'


def space_header(space_id, version, parent, epoch, kind, author, created_ms):
    return (bytes([1]) + space_id + struct.pack('>Q', version) + parent + struct.pack('>I', epoch)
            + bytes([kind]) + author + struct.pack('>q', created_ms))


def space_member(device, sign_pk, agree_pk, login, display, mac):
    data = device + sign_pk + agree_pk
    for text in (login, display, mac):
        raw = text.encode()
        data += struct.pack('>H', len(raw)) + raw
    return data


def space_wrap_info(space_id, epoch, device):
    return lp(SPACE_PREFIX + b'/wrap') + space_id + struct.pack('>I', epoch) + device


def space_snapshot(reason, items):
    data = bytes([1]) + lp(reason.encode()) + struct.pack('>I', len(items))
    for kind, name, value, updated_ms in sorted(items, key=lambda item: (item[0], item[1])):
        data += bytes([1 if kind == 'secret' else 2]) + lp(name.encode())
        data += bytes([1]) + lp(value.encode())
        data += bytes([1]) + struct.pack('>q', updated_ms)
    return data


def space_version(header, keyring, plaintext, epoch_key, space_id, nonce, author_seed):
    payload_key = hkdf(epoch_key, space_id, SPACE_PREFIX + b'/payload', 32)
    aad = hashlib.sha256(lp(header) + lp(keyring)).digest()
    ciphertext = nonce + AESGCM(payload_key).encrypt(nonce, plaintext, aad)
    digest = hashlib.sha256(lp(SPACE_PREFIX + b'/version') + lp(header) + lp(keyring) + lp(ciphertext)).digest()
    signature = Ed25519PrivateKey.from_private_bytes(author_seed).sign(lp(SPACE_PREFIX + b'/signature') + lp(digest))
    wire = lp(header) + lp(keyring) + lp(ciphertext) + signature
    return ciphertext, digest, signature, wire


def space_vectors():
    """fxvault-space/v1 vectors (v0.6.0): Ana shares a scope with Ben (v1), Ben publishes (v2)."""
    base = (9).to_bytes(32, 'little')
    ana_seed, ana_agree, ana_announce = bytes(range(0x80, 0xA0)), bytes(range(0xA0, 0xC0)), bytes(range(0xC0, 0xE0))
    ben_seed, ben_agree, ben_announce = bytes(range(0x10, 0x30)), bytes(range(0x30, 0x50)), bytes(range(0x50, 0x70))
    ana_sign_pk, ben_sign_pk = ed25519_public(ana_seed), ed25519_public(ben_seed)
    ana_agree_pk, ben_agree_pk = x25519(ana_agree, base), x25519(ben_agree, base)
    ana_id, ben_id = device_id(ana_sign_pk, ana_agree_pk), device_id(ben_sign_pk, ben_agree_pk)

    space_id = bytes(range(0xE0, 0xF0))
    epoch_key = bytes(range(0x70, 0x90))
    nonce1, nonce2 = bytes(range(0x90, 0x9C)), bytes(range(0xA0, 0xAC))
    created1, created2 = 1790000000000, 1790000060000
    suite = hpke.Suite(hpke.KEM.X25519, hpke.KDF.HKDF_SHA256, hpke.AEAD.CHACHA20_POLY1305)

    wraps = b''
    for device, agree_pk in ((ana_id, ana_agree_pk), (ben_id, ben_agree_pk)):
        sealed = suite.encrypt(epoch_key, X25519PublicKey.from_public_bytes(agree_pk), info=space_wrap_info(space_id, 1, device))
        wraps += device + struct.pack('>I', 1) + lp(sealed[:32]) + lp(sealed[32:])
    binding = bytes([1]) + lp(b'R_repo-a') + lp(b'owner-a') + lp(b'repo-a') + bytes([1]) + lp(b'production')
    members = (space_member(ana_id, ana_sign_pk, ana_agree_pk, 'user-a', 'Ana', "Ana's Mac")
               + space_member(ben_id, ben_sign_pk, ben_agree_pk, 'user-b', 'Ben', "Ben's Mac"))
    keyring1 = bytes([1]) + binding + struct.pack('>H', 2) + members + struct.pack('>H', 2) + wraps
    header1 = space_header(space_id, 1, bytes(32), 1, 1, ana_id, created1)
    plain1 = space_snapshot('shared', [
        ('secret', 'API_KEY', 'v1', 1789999990000),
        ('variable', 'BASE_URL', 'https://example.com', 1789999990000),
    ])
    ct1, hash1, sig1, wire1 = space_version(header1, keyring1, plain1, epoch_key, space_id, nonce1, ana_seed)

    header2 = space_header(space_id, 2, hash1, 1, 2, ben_id, created2)
    plain2 = space_snapshot('rotate', [
        ('secret', 'API_KEY', 'v2', 1790000050000),
        ('variable', 'BASE_URL', 'https://example.com', 1789999990000),
    ])
    ct2, hash2, sig2, wire2 = space_version(header2, b'', plain2, epoch_key, space_id, nonce2, ben_seed)

    at = '2026-09-21T13:21:00.123Z'
    space_text = str(uuid.UUID(bytes=space_id))
    marker_message = (lp(SPACE_PREFIX + b'/marker') + space_id + struct.pack('>Q', 2) + bytes([2])
                      + lp(hash2) + lp(ben_id) + lp(at.encode()) + lp(b'user-b'))
    marker_signature = Ed25519PrivateKey.from_private_bytes(ben_seed).sign(marker_message)
    marker = json.dumps({
        'at': at, 'by': 'user-b', 'dev': ben_id.hex(), 'f': 1, 'head': hash2.hex(),
        'sig': base64.b64encode(marker_signature).decode(), 'space': space_text, 'state': 'published', 'v': 2,
    }, sort_keys=True, separators=(',', ':'))

    fingerprint_key = hkdf(epoch_key, space_id, SPACE_PREFIX + b'/fingerprint', 32)
    fingerprint = hmac.new(fingerprint_key, bytes([1]) + lp(b'API_KEY') + lp(b'v2'), hashlib.sha256).digest()[:4].hex()

    outputs = {
        'ana_device_id': ana_id.hex(),
        'ben_device_id': ben_id.hex(),
        'fingerprint_API_KEY_v2': fingerprint,
        'hash1': hash1.hex(),
        'hash2': hash2.hex(),
        'header1': header1.hex(),
        'header2': header2.hex(),
        'keyring1': keyring1.hex(),
        'marker': marker,
        'marker_message': marker_message.hex(),
        'payload1': ct1.hex(),
        'payload2': ct2.hex(),
        'plaintext1': plain1.hex(),
        'plaintext2': plain2.hex(),
        'signature1': sig1.hex(),
        'signature2': sig2.hex(),
        'wire1': wire1.hex(),
        'wire2': wire2.hex(),
    }
    inputs = {
        'anaSigningSeed': ana_seed.hex(), 'anaAgreementKey': ana_agree.hex(), 'anaAnnounceKey': ana_announce.hex(),
        'benSigningSeed': ben_seed.hex(), 'benAgreementKey': ben_agree.hex(), 'benAnnounceKey': ben_announce.hex(),
        'spaceID': space_text, 'epochKey': epoch_key.hex(), 'nonce1': nonce1.hex(), 'nonce2': nonce2.hex(),
        'created1': created1, 'created2': created2, 'spaceLabelPrefix': SPACE_PREFIX.decode(),
    }
    return inputs, outputs


def write_document(path, description, inputs, outputs):
    document = {'description': description, 'inputs': inputs, 'outputs': outputs}
    with open(path, 'w') as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write('\n')


def main():
    if len(sys.argv) >= 2 and sys.argv[1] in ('--space-lines', '--write-space'):
        inputs, outputs = space_vectors()
        if sys.argv[1] == '--write-space' and len(sys.argv) >= 3:
            write_document(
                sys.argv[2],
                'FX Vault shared spaces (fxvault-space/v1, v0.6.0) known-answer vectors. Generated by crosscheck.py '
                '(Ed25519 signatures are RFC 8032 deterministic and HPKE wraps use random ephemerals; Swift verifies '
                'and opens them, and reproduces everything else byte for byte).',
                inputs, outputs)
        else:
            for key in sorted(outputs):
                sys.stdout.write(f'space_{key}={outputs[key]}\n')
        return
    if len(sys.argv) >= 2 and sys.argv[1] in ('--team-lines', '--write-team'):
        inputs, outputs = team_vectors()
        if sys.argv[1] == '--write-team' and len(sys.argv) >= 3:
            write_document(
                sys.argv[2],
                'FX Vault teammates (fxvault-team/v1, v0.5.0) known-answer vectors. Generated by crosscheck.py '
                '(Ed25519 signatures are RFC 8032 deterministic; Swift verifies them).',
                inputs, outputs)
        else:
            for key in sorted(outputs):
                sys.stdout.write(f'team_{key}={outputs[key]}\n')
        return
    if len(sys.argv) >= 2 and sys.argv[1] in ('--chat-lines', '--write-chat'):
        inputs, outputs = chat_vectors()
        if sys.argv[1] == '--write-chat' and len(sys.argv) >= 3:
            write_document(
                sys.argv[2],
                'FX Vault nearby chat (fxvault-chat/v1) known-answer vectors. Generated by crosscheck.py '
                'and checked byte-for-byte against NearbyProtocolReference.swift.',
                inputs, outputs)
        else:
            for key in sorted(outputs):
                sys.stdout.write(f'chat_{key}={outputs[key]}\n')
        return
    inputs, outputs = vectors()
    if len(sys.argv) >= 3 and sys.argv[1] == '--write':
        document = {
            'description': 'FX Vault nearby v1 and .fxvault v1 known-answer vectors (tasks/todo.md §9.1, §9.4). '
                           'Generated by crosscheck.py and checked byte-for-byte against NearbyProtocolReference.swift.',
            'inputs': inputs,
            'outputs': outputs,
        }
        with open(sys.argv[2], 'w') as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write('\n')
    else:
        for key in sorted(outputs):
            sys.stdout.write(f'{key}={outputs[key]}\n')


if __name__ == '__main__':
    main()
