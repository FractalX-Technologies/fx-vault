"""Independent Python vectors for the `.fxvault` format 2 file (v0.9.0, SHARING-PROTOCOL.md §2.1).

Passphrase mode: the header, AES-256-GCM under a fixed key (Argon2id is not re-run here; the
v1 vectors already pin it) and the whole file, which Swift reproduces byte for byte.

Teammates mode: a file Sender seals for Ana and Ben. HPKE (RFC 9180 base mode, DHKEM(X25519,
HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305) is implemented here from the RFC with fixed
ephemeral keys, so the file is deterministic, and every wrap is opened again with the
`cryptography` package's own HPKE as an independent check. X25519 and HKDF come from the
standard library (RFC 7748, RFC 5869) and are re-checked against `cryptography`. Ed25519
signatures are RFC 8032 deterministic; CryptoKit signs with randomness and seals HPKE with random
ephemerals, so Swift opens and verifies this file and reproduces its header, slots, signed
message and ciphertext.

Usage (from a venv with `cryptography` installed):
  python3 file_v2_kat.py --lines                 # key=value lines
  python3 file_v2_kat.py --write file_v2_kat.json
"""
import hashlib
import hmac
import json
import struct
import sys

from cryptography.hazmat.primitives import hpke, serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305

P = 2**255 - 19
A24 = 121665
BASE = (9).to_bytes(32, 'little')
MAGIC = bytes([0x46, 0x58, 0x56, 0x41, 0x55, 0x4C, 0x54, 0x1A])
TEAM_PREFIX = b'fxvault/team/v1'
SLOT_LABEL = b'fxvault/file/v2/slot'
WRAP_LABEL = b'fxvault/file/v2/wrap'
SIGN_LABEL = b'fxvault/file/v2/sign'


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
        a = (x2 + z2) % P; aa = a * a % P; b = (x2 - z2) % P; bb = b * b % P; e = (aa - bb) % P
        c = (x3 + z3) % P; d = (x3 - z3) % P; da = d * a % P; cb = c * b % P
        x3 = (da + cb) ** 2 % P; z3 = x1 * (da - cb) ** 2 % P; x2 = aa * bb % P; z2 = e * (aa + A24 * e) % P
    if swap:
        x2, x3, z2, z3 = x3, x2, z3, z2
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, 'little')


def x25519_checked(private, public):
    """RFC 7748 here, compared with `cryptography`."""
    ours = x25519(private, public)
    theirs = X25519PrivateKey.from_private_bytes(private).exchange(X25519PublicKey.from_public_bytes(public))
    assert ours == theirs, 'X25519 mismatch'
    return ours


def lp(d):
    return struct.pack('>I', len(d)) + d


def hkdf_extract(salt, ikm):
    return hmac.new(salt, ikm, hashlib.sha256).digest()


def hkdf_expand(prk, info, n):
    out, t, i = b'', b'', 1
    while len(out) < n:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        out += t
        i += 1
    return out[:n]


# RFC 9180 base mode, DHKEM(X25519, HKDF-SHA256) = 0x0020, HKDF-SHA256 = 0x0001,
# ChaCha20-Poly1305 = 0x0003.
KEM_SUITE = b'KEM' + struct.pack('>H', 0x0020)
HPKE_SUITE = b'HPKE' + struct.pack('>HHH', 0x0020, 0x0001, 0x0003)


def labeled_extract(suite, salt, label, ikm):
    return hkdf_extract(salt, b'HPKE-v1' + suite + label + ikm)


def labeled_expand(suite, prk, label, info, n):
    return hkdf_expand(prk, struct.pack('>H', n) + b'HPKE-v1' + suite + label + info, n)


def hpke_seal(recipient_public, ephemeral_private, info, plaintext):
    """SetupBaseS with a fixed ephemeral key, then Seal at sequence 0 with empty AAD."""
    enc = x25519(ephemeral_private, BASE)
    dh = x25519_checked(ephemeral_private, recipient_public)
    eae_prk = labeled_extract(KEM_SUITE, b'', b'eae_prk', dh)
    shared_secret = labeled_expand(KEM_SUITE, eae_prk, b'shared_secret', enc + recipient_public, 32)
    psk_id_hash = labeled_extract(HPKE_SUITE, b'', b'psk_id_hash', b'')
    info_hash = labeled_extract(HPKE_SUITE, b'', b'info_hash', info)
    context = bytes([0]) + psk_id_hash + info_hash
    secret = labeled_extract(HPKE_SUITE, shared_secret, b'secret', b'')
    key = labeled_expand(HPKE_SUITE, secret, b'key', context, 32)
    base_nonce = labeled_expand(HPKE_SUITE, secret, b'base_nonce', context, 12)
    return enc, ChaCha20Poly1305(key).encrypt(base_nonce, plaintext, b'')


def ed25519_public(seed):
    return Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def device_id(sign_pk, agree_pk):
    return hashlib.sha256(lp(TEAM_PREFIX + b'/device-id') + lp(sign_pk) + lp(agree_pk)).digest()[:16]


def header_v2(mode, salt, nonce, ops=0, mem_kib=0, recipients=0):
    h = MAGIC + struct.pack('>HH', 2, 64)
    if mode == 1:
        h += bytes([1, 1]) + struct.pack('>II', ops, mem_kib) + bytes([1])
    else:
        h += bytes([0, 1]) + struct.pack('>II', 0, 0) + bytes([0])
    h += bytes([0]) + salt + nonce + bytes([mode, recipients])
    return h + bytes(64 - len(h))


def slot_id(salt, device):
    return hmac.new(salt, lp(SLOT_LABEL) + device, hashlib.sha256).digest()[:8]


def passphrase_vectors():
    key = bytes([0x42]) * 32
    salt, nonce = bytes(range(0x80, 0x90)), bytes(range(0x90, 0x9C))
    payload = b'{"schema":"io.fractalx.fxvault.share","schemaVersion":4}'
    header = header_v2(1, salt, nonce, ops=3, mem_kib=65536)
    sealed = AESGCM(key).encrypt(nonce, payload, header)
    inputs = {
        'passphraseKey': key.hex(), 'passphraseOpsLimit': 3, 'passphraseMemLimitKiB': 65536,
        'passphraseSalt': salt.hex(), 'passphraseNonce': nonce.hex(), 'passphrasePayloadUTF8': payload.decode(),
    }
    outputs = {'passphrase_header': header.hex(), 'passphrase_file': (header + sealed).hex()}
    return inputs, outputs


def teammates_vectors():
    people = {
        'sender': (bytes(range(0xA0, 0xC0)), bytes(range(0xC0, 0xE0)), bytes(range(0xE0, 0x100))),
        'ana': (bytes(range(0x10, 0x30)), bytes(range(0x30, 0x50)), bytes(range(0x50, 0x70))),
        'ben': (bytes(range(0x70, 0x90)), bytes(range(0x01, 0x21)), bytes(range(0x21, 0x41))),
    }
    keys = {}
    for name, (seed, agree, announce) in people.items():
        sign_pk, agree_pk = ed25519_public(seed), x25519(agree, BASE)
        keys[name] = (seed, agree, announce, sign_pk, agree_pk, device_id(sign_pk, agree_pk))

    salt, nonce = bytes(range(0x00, 0x10)), bytes(range(0x20, 0x2C))
    content_key = bytes(range(0x40, 0x60))
    ephemerals = {'ana': bytes(range(0x60, 0x80)), 'ben': bytes(range(0x90, 0xB0))}
    payload = b'{"schema":"io.fractalx.fxvault.share","schemaVersion":4,"scope":"bundle"}'
    header = header_v2(2, salt, nonce, recipients=2)
    info = lp(WRAP_LABEL) + header
    suite = hpke.Suite(hpke.KEM.X25519, hpke.KDF.HKDF_SHA256, hpke.AEAD.CHACHA20_POLY1305)

    slots = []
    for name in ('ana', 'ben'):
        _, agree, _, _, agree_pk, device = keys[name]
        enc, wrapped = hpke_seal(agree_pk, ephemerals[name], info, content_key)
        opened = suite.decrypt(enc + wrapped, X25519PrivateKey.from_private_bytes(agree), info=info)
        assert opened == content_key, 'HPKE cross-check failed'
        slots.append((slot_id(salt, device), enc, wrapped))
    slots.sort(key=lambda slot: slot[0])
    slot_bytes = b''.join(s + e + w for s, e, w in slots)

    sender_seed, _, sender_announce, _, _, sender_device = keys['sender']
    message = (lp(SIGN_LABEL) + lp(header) + lp(slot_bytes) + lp(sender_device) + lp(sender_announce)
               + lp(hashlib.sha256(payload).digest()))
    signature = Ed25519PrivateKey.from_private_bytes(sender_seed).sign(message)
    plaintext = sender_device + sender_announce + signature + payload
    sealed = AESGCM(content_key).encrypt(nonce, plaintext, header + slot_bytes)
    file = header + slot_bytes + sealed

    inputs = {
        'teammatesSalt': salt.hex(), 'teammatesNonce': nonce.hex(), 'teammatesContentKey': content_key.hex(),
        'teammatesPayloadUTF8': payload.decode(),
        'anaEphemeralKey': ephemerals['ana'].hex(), 'benEphemeralKey': ephemerals['ben'].hex(),
    }
    for name, (seed, agree, announce, _, _, _) in keys.items():
        inputs[f'{name}SigningSeed'] = seed.hex()
        inputs[f'{name}AgreementKey'] = agree.hex()
        inputs[f'{name}AnnounceKey'] = announce.hex()
    outputs = {
        'teammates_header': header.hex(),
        'teammates_slots': slot_bytes.hex(),
        'teammates_signed_message': message.hex(),
        'teammates_signature': signature.hex(),
        'teammates_plaintext': plaintext.hex(),
        'teammates_file': file.hex(),
        'sender_device_id': sender_device.hex(),
        'ana_device_id': keys['ana'][5].hex(),
        'ben_device_id': keys['ben'][5].hex(),
        'ana_slot_id': slot_id(salt, keys['ana'][5]).hex(),
        'ben_slot_id': slot_id(salt, keys['ben'][5]).hex(),
    }
    return inputs, outputs


def vectors():
    inputs, outputs = passphrase_vectors()
    more_inputs, more_outputs = teammates_vectors()
    inputs.update(more_inputs)
    outputs.update(more_outputs)
    inputs['labels'] = ' '.join(label.decode() for label in (SLOT_LABEL, WRAP_LABEL, SIGN_LABEL))
    return inputs, outputs


def main():
    inputs, outputs = vectors()
    if len(sys.argv) >= 3 and sys.argv[1] == '--write':
        document = {
            'description': 'FX Vault .fxvault format 2 (v0.9.0) known-answer vectors. Generated by '
                           'kat/file_v2_kat.py: passphrase mode byte for byte; teammates mode with '
                           'HPKE implemented from RFC 9180 (fixed ephemerals, cross-checked with '
                           'cryptography) and RFC 8032 signatures, which Swift opens and verifies.',
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
