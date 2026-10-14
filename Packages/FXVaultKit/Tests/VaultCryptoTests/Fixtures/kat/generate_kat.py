#!/usr/bin/env python3
"""Known-answer vectors for VaultCrypto, generated independently of the Swift code.

Implements tasks/todo.md §5.1-§5.4 from the plan text using argon2-cffi (Argon2id, the
reference C implementation) and pyca/cryptography (AES-256-GCM, HKDF-SHA256, HMAC-SHA256),
never libsodium or CryptoKit. The Swift tests in Tests/VaultCryptoTests/KATTests.swift load
the JSON this script writes and must reproduce every byte.

Run from anywhere (it writes next to itself):
    python3 -m venv <scratch>/venv && <scratch>/venv/bin/pip install argon2-cffi cryptography
    <scratch>/venv/bin/python -I generate_kat.py

All inputs are fixed synthetic values (no real secrets). JSON keys avoid words such as
"key", "secret", "token" and "password" so secret scanners do not mistake vectors for
credentials.
"""

import hashlib
import hmac
import json
import pathlib
import struct
import unicodedata
import uuid

from argon2.low_level import Type, hash_secret_raw
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

OUT = pathlib.Path(__file__).resolve().parent / "kat_vectors.json"

FIELD_DOMAIN = b"fxvault/v1/field"
WRAP_DOMAIN = b"fxvault/v1/dek-wrap"
FIELD_ENC_INFO = b"fxvault/v1/field-enc"
FINGERPRINT_INFO = b"fxvault/v1/fingerprint"
KCV_LABEL = b"fxvault/v1/kcv"
RECOVERY_KEK_INFO = b"fxvault/v1/kek/recovery"
RECOVERY_CHECK_LABEL = b"fxvault/v1/recovery-check"
CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
KIB = 1024


def seq(start, count):
    return bytes((start + i) & 0xFF for i in range(count))


def lp(data: bytes) -> bytes:
    """LP(x) = u32be(len(x)) || x  (§5.2)."""
    return struct.pack(">I", len(data)) + data


def hkdf(ikm: bytes, salt: bytes, info: bytes, length: int = 32) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(ikm)


def argon2id(pw: bytes, salt: bytes, t: int, m_kib: int) -> bytes:
    return hash_secret_raw(secret=pw, salt=salt, time_cost=t, memory_cost=m_kib,
                           parallelism=1, hash_len=32, type=Type.ID)


def field_aad(table, column, row, repo, env, kind, name, dek_version) -> bytes:
    """§5.4: LP(domain) || LP(table) || LP(column) || LP(row 16B) || LP(repo 16B)
    || LP(env 16B | empty) || LP(kind) || LP(name_for_column) || u32be(dek_version)."""
    env_bytes = env.bytes if env is not None else b""
    return (lp(FIELD_DOMAIN) + lp(table.encode()) + lp(column.encode()) + lp(row.bytes)
            + lp(repo.bytes) + lp(env_bytes) + lp(kind.encode()) + lp(name.encode())
            + struct.pack(">I", dek_version))


def wrap_aad(fmt, aead, method, vault_id, dek_version, kdf_alg, ops, mem_bytes, salt) -> bytes:
    """§5.2: u8(format) || u8(aead) || LP(domain) || LP(method) || LP(vault_id)
    || u32be(dek_version) || u8(kdf_alg) || u32be(ops|0) || u64be(mem|0) || LP(salt|empty)."""
    return (bytes([fmt, aead]) + lp(WRAP_DOMAIN) + lp(method.encode()) + lp(vault_id)
            + struct.pack(">I", dek_version) + bytes([kdf_alg]) + struct.pack(">I", ops)
            + struct.pack(">Q", mem_bytes) + lp(salt))


def crockford_encode(data: bytes) -> str:
    """MSB-first 5-bit groups; the final group is padded with zero bits."""
    bits = "".join(f"{b:08b}" for b in data)
    if len(bits) % 5:
        bits += "0" * (5 - len(bits) % 5)
    return "".join(CROCKFORD[int(bits[i:i + 5], 2)] for i in range(0, len(bits), 5))


def recovery_vector(material: bytes):
    check = hashlib.sha256(RECOVERY_CHECK_LABEL + material).digest()[:3]
    text = crockford_encode(material + check)
    groups = [text[i:i + 4] for i in range(0, len(text), 4)]
    return {"material_hex": material.hex(), "checksum_hex": check.hex(), "text": text,
            "groups": groups}


def main():
    vectors = {"generator": "generate_kat.py (argon2-cffi + pyca/cryptography)"}

    # --- Argon2id (§5.1 K_pw, D8). Passwords are NFC-normalized before UTF-8 encoding. ---
    argon_cases = [
        ("ascii", "correct horse battery staple", seq(0x00, 16), 1, 8 * KIB, False),
        ("nfc-latin", "Producción-Contraseña", seq(0x10, 16), 2, 64 * KIB, False),
        ("empty", "", seq(0x30, 16), 1, 8 * KIB, False),
        ("arabic-emoji", "كلمة-السر-🔐", seq(0x40, 16), 1, 8 * KIB, False),
        ("moderate", "FX Vault moderate KAT", seq(0x20, 16), 3, 256 * KIB, True),
    ]
    vectors["argon2id"] = []
    for label, text, salt, t, m_kib, moderate in argon_cases:
        pw = unicodedata.normalize("NFC", text).encode()
        vectors["argon2id"].append({
            "label": label, "text": text, "pw_utf8_hex": pw.hex(), "salt_hex": salt.hex(),
            "ops": t, "mem_bytes": m_kib * KIB, "out_hex": argon2id(pw, salt, t, m_kib).hex(),
            "moderate": moderate,
        })

    # --- Key hierarchy (§5.1). ---
    dek = seq(0x40, 32)
    vault_id = seq(0x60, 16)
    recovery_material = seq(0x70, 32)
    k_field = hkdf(dek, vault_id, FIELD_ENC_INFO)
    k_fp = hkdf(dek, vault_id, FINGERPRINT_INFO)
    fp_row = uuid.UUID("3f2c8a1e-5b7d-4c9e-8f10-2a3b4c5d6e7f")
    fp_value = b"FXV_FIXTURE_VALUE"
    vectors["hierarchy"] = {
        "dek_hex": dek.hex(), "vault_id_hex": vault_id.hex(),
        "k_field_hex": k_field.hex(), "k_fp_hex": k_fp.hex(),
        "kcv_hex": hmac.new(dek, KCV_LABEL, hashlib.sha256).digest()[:16].hex(),
        "recovery_material_hex": recovery_material.hex(),
        "recovery_kek_hex": hkdf(recovery_material, vault_id, RECOVERY_KEK_INFO).hex(),
        "fingerprint": {
            "row": str(fp_row), "value_hex": fp_value.hex(),
            "out_hex": hmac.new(k_fp, lp(fp_row.bytes) + fp_value, hashlib.sha256).hexdigest(),
        },
    }

    # --- Field encryption (§5.4): blob = 0x01 || nonce || ct || tag. ---
    row = uuid.UUID("0b7e2f5a-9c41-4d3e-a6b2-7f8e9d0c1b2a")
    repo = uuid.UUID("5d6c7b8a-1e2f-4a3b-9c4d-0e1f2a3b4c5d")
    env = uuid.UUID("9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d")
    field_cases = [
        ("env-secret-value", "config_items", "value_ct", row, repo, env, "secret",
         "FXV_FIXTURE_NAME", 1, b"FXV_FIXTURE_SECRET_VALUE", seq(0xA0, 12)),
        ("repo-variable-synced-empty", "config_items", "synced_value_ct", row, repo, None,
         "variable", "FXV_FIXTURE_SYNCED", 7, b"", seq(0xB0, 12)),
        ("env-variable-multiline", "config_items", "value_ct", row, repo, env, "variable",
         "FXV_FIXTURE_MULTI", 2, "line1\nline2 ✓\t\"'".encode(), seq(0xC0, 12)),
    ]
    vectors["field"] = []
    for label, table, column, r, rp, e, kind, name, ver, plain, nonce in field_cases:
        aad = field_aad(table, column, r, rp, e, kind, name, ver)
        sealed = AESGCM(k_field).encrypt(nonce, plain, aad)
        vectors["field"].append({
            "label": label, "aes_k_hex": k_field.hex(), "table": table, "column": column,
            "row": str(r), "repo": str(rp), "env": str(e) if e else None, "kind": kind,
            "name": name, "dek_version": ver, "plain_hex": plain.hex(),
            "nonce_hex": nonce.hex(), "aad_hex": aad.hex(),
            "blob_hex": (b"\x01" + nonce + sealed).hex(),
        })

    # --- DEK wraps (§5.2): 62 bytes = fmt || aead || nonce || ct(32) || tag. ---
    pw_text = "FXV fixture pässwörd ✓"
    pw = unicodedata.normalize("NFC", pw_text).encode()
    pw_salt = seq(0xB0, 16)
    pw_ops, pw_mem = 1, 8 * KIB * KIB
    kek_pw = argon2id(pw, pw_salt, pw_ops, pw_mem // KIB)
    wrap_nonce = seq(0xD0, 12)
    aad_pw = wrap_aad(1, 1, "password", vault_id, 1, 1, pw_ops, pw_mem, pw_salt)
    wrapped_pw = bytes([1, 1]) + wrap_nonce + AESGCM(kek_pw).encrypt(wrap_nonce, dek, aad_pw)
    kek_rec = hkdf(recovery_material, vault_id, RECOVERY_KEK_INFO)
    rec_nonce = seq(0xE0, 12)
    aad_rec = wrap_aad(1, 1, "recovery", vault_id, 3, 2, 0, 0, b"")
    wrapped_rec = bytes([1, 1]) + rec_nonce + AESGCM(kek_rec).encrypt(rec_nonce, dek, aad_rec)
    assert len(wrapped_pw) == 62 and len(wrapped_rec) == 62
    vectors["wrap"] = {
        "password": {
            "text": pw_text, "salt_hex": pw_salt.hex(), "ops": pw_ops, "mem_bytes": pw_mem,
            "vault_id_hex": vault_id.hex(), "dek_version": 1, "dek_hex": dek.hex(),
            "kek_hex": kek_pw.hex(), "nonce_hex": wrap_nonce.hex(), "aad_hex": aad_pw.hex(),
            "wrapped_hex": wrapped_pw.hex(),
        },
        "recovery": {
            "material_hex": recovery_material.hex(), "vault_id_hex": vault_id.hex(),
            "dek_version": 3, "dek_hex": dek.hex(), "kek_hex": kek_rec.hex(),
            "nonce_hex": rec_nonce.hex(), "aad_hex": aad_rec.hex(),
            "wrapped_hex": wrapped_rec.hex(),
        },
    }

    # --- Recovery key text (§5.3) and Crockford Base32. ---
    vectors["recovery"] = [recovery_vector(m) for m in
                           (recovery_material, bytes(32), b"\xff" * 32, seq(0x13, 32))]
    vectors["crockford"] = [{"in_hex": seq(0x5A, n).hex(), "text": crockford_encode(seq(0x5A, n))}
                            for n in range(0, 11)]

    OUT.write_text(json.dumps(vectors, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
