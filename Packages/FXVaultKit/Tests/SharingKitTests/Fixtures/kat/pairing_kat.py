"""Independent Python vectors for FX Vault remote pairing (fxvault/pair-remote/v1, v0.9.0).

Two `.fxvcard` files: Ana's invitation and Ben's reply, the 6-word code, and the HPKE-sealed
announce key (RFC 9180, X25519 / HKDF-SHA256 / ChaCha20-Poly1305, a random ephemeral: Swift
opens it). Ed25519 signatures are RFC 8032 deterministic here; CryptoKit signs with randomness,
so Swift verifies them and reproduces everything else byte for byte. The code is drawn from the
bundled EFF wordlist (checked against its pinned SHA-256, hyphenated words removed).

Usage (from a venv with `cryptography` installed):
  python3 pairing_kat.py --lines                    # key=value lines
  python3 pairing_kat.py --write pairing_kat.json
"""

import hashlib
import json
import os
import struct
import sys

from cryptography.hazmat.primitives import hpke
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives import serialization

from crosscheck import device_id, ed25519_public, hkdf, lp

PREFIX = b'fxvault/pair-remote/v1'
MAGIC = bytes([0x46, 0x58, 0x56, 0x43, 0x41, 0x52, 0x44, 0x1A])
VERSION = 1
KIND_INVITATION, KIND_REPLY = 1, 2
WORDLIST_SHA256 = 'addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e'
WORDLIST = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        '..', '..', '..', '..', 'Sources', 'SharingKit', 'Resources', 'eff_large_wordlist.txt')


def words():
    data = open(WORDLIST, 'rb').read()
    assert hashlib.sha256(data).hexdigest() == WORDLIST_SHA256
    listed = [line.split('\t')[-1] for line in data.decode().splitlines() if line]
    usable = [w for w in listed if w.isascii() and w.isalpha() and w.islower()]
    assert len(usable) == 7772
    return usable


def agreement_public(key):
    return X25519PrivateKey.from_private_bytes(key).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def public_card(sign_pk, agree_pk, login, display, mac):
    data = device_id(sign_pk, agree_pk) + sign_pk + agree_pk
    for text in (login, display, mac):
        raw = text.encode()
        data += struct.pack('>H', len(raw)) + raw
    return data


def code(card_a, nonce_a, card_b, nonce_b, wordlist):
    transcript = lp(PREFIX + b'/code') + lp(card_a + nonce_a) + lp(card_b + nonce_b)
    stream = hkdf(transcript, b'', PREFIX + b'/code-words', 128)
    bound = 65536 // len(wordlist) * len(wordlist)
    chosen, offset = [], 0
    while len(chosen) < 6:
        value = struct.unpack('>H', stream[offset:offset + 2])[0]
        offset += 2
        if value < bound:
            chosen.append(wordlist[value % len(wordlist)])
    return stream, '-'.join(chosen)


def vectors():
    ana_seed, ana_agree, ana_announce = bytes(range(0x01, 0x21)), bytes(range(0x21, 0x41)), bytes(range(0x41, 0x61))
    ben_seed, ben_agree, ben_announce = bytes(range(0x61, 0x81)), bytes(range(0x81, 0xA1)), bytes(range(0xA1, 0xC1))
    ana_sign_pk, ana_agree_pk = ed25519_public(ana_seed), agreement_public(ana_agree)
    ben_sign_pk, ben_agree_pk = ed25519_public(ben_seed), agreement_public(ben_agree)
    nonce_a, nonce_b = bytes(range(0xC0, 0xE0)), bytes(range(0xE0, 0x100))
    created_a, created_b = 1_800_000_000, 1_800_000_600

    card_a = public_card(ana_sign_pk, ana_agree_pk, 'user-a', 'Ana', "Ana's Mac")
    card_b = public_card(ben_sign_pk, ben_agree_pk, 'user-b', 'Ben', "Ben's Mac")

    signed_a = card_a + struct.pack('>Q', created_a) + nonce_a
    sig_a = Ed25519PrivateKey.from_private_bytes(ana_seed).sign(lp(PREFIX + b'/invite') + lp(signed_a))
    invitation = MAGIC + bytes([VERSION, KIND_INVITATION]) + signed_a + sig_a

    info = lp(PREFIX + b'/announce') + hashlib.sha256(invitation).digest() + device_id(ben_sign_pk, ben_agree_pk)
    suite = hpke.Suite(hpke.KEM.X25519, hpke.KDF.HKDF_SHA256, hpke.AEAD.CHACHA20_POLY1305)
    sealed = suite.encrypt(ben_announce, X25519PublicKey.from_public_bytes(ana_agree_pk), info=info)
    body = (struct.pack('>I', len(invitation)) + invitation + card_b + struct.pack('>Q', created_b) + nonce_b
            + sealed[:32] + sealed[32:])
    sig_b = Ed25519PrivateKey.from_private_bytes(ben_seed).sign(lp(PREFIX + b'/reply') + lp(body))
    reply = MAGIC + bytes([VERSION, KIND_REPLY]) + body + sig_b

    stream, words_text = code(card_a, nonce_a, card_b, nonce_b, words())
    inputs = {
        'anaSigningSeed': ana_seed.hex(), 'anaAgreementKey': ana_agree.hex(), 'anaAnnounceKey': ana_announce.hex(),
        'benSigningSeed': ben_seed.hex(), 'benAgreementKey': ben_agree.hex(), 'benAnnounceKey': ben_announce.hex(),
        'nonceA': nonce_a.hex(), 'nonceB': nonce_b.hex(), 'createdA': created_a, 'createdB': created_b,
        'labelPrefix': PREFIX.decode(),
    }
    outputs = {
        'publicCardA': card_a.hex(), 'publicCardB': card_b.hex(),
        'invitation': invitation.hex(), 'reply': reply.hex(),
        'announceInfo': info.hex(), 'codeStream': stream.hex(), 'code': words_text,
    }
    return inputs, outputs


def main():
    inputs, outputs = vectors()
    if len(sys.argv) >= 3 and sys.argv[1] == '--write':
        document = {
            'description': 'FX Vault remote pairing (fxvault/pair-remote/v1, v0.9.0) known-answer vectors. Generated by '
                           'pairing_kat.py (Ed25519 signatures are RFC 8032 deterministic and the HPKE seal uses a random '
                           'ephemeral; Swift verifies and opens them, and reproduces everything else byte for byte).',
            'inputs': inputs,
            'outputs': outputs,
        }
        with open(sys.argv[2], 'w') as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write('\n')
    else:
        for key in sorted(outputs):
            sys.stdout.write(f'pairing_{key}={outputs[key]}\n')


if __name__ == '__main__':
    main()
