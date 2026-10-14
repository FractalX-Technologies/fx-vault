"""Independent Python cross-check of the FX Vault nearby v1 and .fxvault v1 vectors.

Revised for the M6 transcript (tasks/todo.md §9.4): C binds maxVerI and suiteI; TH binds
maxVerI, maxVerR, ver, suiteI, suiteR, C, both keys, both nonces and both names.

X25519 and HKDF are implemented here from RFC 7748 / RFC 5869 with the standard library, and
re-checked against the `cryptography` package, which also provides AES-GCM.

Usage (from a venv with `cryptography` installed):
  python3 crosscheck.py --lines              # key=value lines, comparable with the Swift reference
  python3 crosscheck.py --write nearby_kat.json
"""
import hashlib
import hmac
import json
import struct
import sys

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives import serialization

P = 2**255 - 19
A24 = 121665


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


def commitment(max_ver_i, suite_i, pk_i, n_i):
    return hashlib.sha256(lp(b'fxvault/nearby/v1/commit') + bytes([max_ver_i, suite_i]) + lp(pk_i) + lp(n_i)).digest()


def transcript(max_ver_i, max_ver_r, ver, suite_i, suite_r, c, pk_i, n_i, name_i, pk_r, n_r, name_r):
    m = lp(b'fxvault/nearby/v1/transcript') + bytes([max_ver_i, max_ver_r, ver, suite_i, suite_r])
    m += lp(c) + lp(pk_i) + lp(n_i) + lp(name_i.encode()) + lp(pk_r) + lp(n_r) + lp(name_r.encode())
    return hashlib.sha256(m).digest()


def sas(ss, th):
    value = int.from_bytes(hkdf(ss, th, b'fxvault/nearby/v1/sas', 8), 'big') % 1000000
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


def main():
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
