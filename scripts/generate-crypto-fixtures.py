#!/usr/bin/env python3
"""Generate the synthetic Vaultwarden crypto known-answer fixtures.

This is the versioned VaultSquire fixture recipe required by ADR 0005. It
derives every expected byte from fixed synthetic canary inputs using the
Python standard library (PBKDF2, HMAC, SHA-256, HKDF-Expand) and the system
OpenSSL command-line tool (AES-256-CBC, RSA-2048 OAEP-SHA1), then emits
VaultSquireTests/VaultwardenCryptoFixtures.swift.

Provenance rules:
- Every secret-like value carries the VSQ-Canary marker and exists only for
  these tests. No production data, provider source, or upstream test value is
  consulted or copied.
- All symmetric vectors are deterministic and byte-regenerable from this
  recipe. The RSA key pair and OAEP ciphertexts are NOT byte-regenerable
  because RSA-OAEP encryption is randomized; regeneration produces a fresh
  key pair whose fixtures still satisfy the same decrypt assertions. The
  committed RSA material is itself synthetic fixture data.
- Record the emitted file's SHA-256 (printed on completion) in the fixture
  review; rerun with --check to verify the committed file matches this
  recipe's deterministic sections.

Construction facts implemented here follow IMPLEMENTATION_REPORT.md sections
on key derivation, stretching, and encrypted strings (L335-L470): PBKDF2 and
Argon2id KDF identifiers 0/1; salt = UTF8(trim(lowercase(email))) for PBKDF2;
auth hash = Base64(PBKDF2-HMAC-SHA256(masterKey, UTF8(password), 1, 32));
HKDF-SHA256 Expand-only with the master key as PRK and info strings
"enc"/"mac"; EncString type 2 = "2.<b64 iv>|<b64 ct>|<b64 mac>" with
AES-256-CBC/PKCS7 under the first 32 key bytes and HMAC-SHA256 over
IV||ciphertext under the last 32 key bytes. Argon2id vectors are not
generated: the dependency is not adopted and the operation fails closed.
"""

import argparse
import base64
import hashlib
import hmac
import pathlib
import subprocess
import sys
import tempfile

RECIPE_REVISION = "1"

CANARY = "VSQ-Canary"
EMAIL_RAW = "  VSQ-Canary-User@Example.COM  "
PASSWORD = "VSQ-Canary-Master-Password-πßé"
PASSWORD_WHITESPACE = "  VSQ-Canary-Padded-Password  "
ITEM_PLAINTEXT = "VSQ-Canary-item-plaintext-0001"

PBKDF2_ITERATION_CASES = [100000, 600000]


def normalized_email(raw: str) -> str:
    return raw.strip().lower()


def hkdf_expand_sha256(prk: bytes, info: bytes, length: int) -> bytes:
    # RFC 5869 section 2.3 Expand only: the caller supplies the PRK directly.
    output = b""
    block = b""
    counter = 1
    while len(output) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        output += block
        counter += 1
    return output[:length]


def stretch_master_key(master_key: bytes) -> bytes:
    return hkdf_expand_sha256(master_key, b"enc", 32) + hkdf_expand_sha256(
        master_key, b"mac", 32
    )


def derive_master_key(password: str, email_raw: str, iterations: int) -> bytes:
    return hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        normalized_email(email_raw).encode("utf-8"),
        iterations,
        dklen=32,
    )


def auth_hash(master_key: bytes, password: str) -> str:
    digest = hashlib.pbkdf2_hmac(
        "sha256", master_key, password.encode("utf-8"), 1, dklen=32
    )
    return base64.b64encode(digest).decode("ascii")


def deterministic_bytes(label: str, length: int) -> bytes:
    output = b""
    counter = 0
    while len(output) < length:
        output += hashlib.sha256(f"{CANARY}-{label}-{counter}".encode()).digest()
        counter += 1
    return output[:length]


def openssl_aes_cbc_encrypt(key32: bytes, iv16: bytes, plaintext: bytes) -> bytes:
    with tempfile.TemporaryDirectory() as tmp:
        inp = pathlib.Path(tmp) / "in.bin"
        out = pathlib.Path(tmp) / "out.bin"
        inp.write_bytes(plaintext)
        subprocess.run(
            [
                "openssl", "enc", "-aes-256-cbc", "-nosalt",
                "-K", key32.hex(), "-iv", iv16.hex(),
                "-in", str(inp), "-out", str(out),
            ],
            check=True,
        )
        return out.read_bytes()


def enc_string_type2(key64: bytes, iv16: bytes, plaintext: bytes) -> str:
    ciphertext = openssl_aes_cbc_encrypt(key64[:32], iv16, plaintext)
    mac = hmac.new(key64[32:], iv16 + ciphertext, hashlib.sha256).digest()
    return "2.{}|{}|{}".format(
        base64.b64encode(iv16).decode("ascii"),
        base64.b64encode(ciphertext).decode("ascii"),
        base64.b64encode(mac).decode("ascii"),
    )


def enc_string_type0(key32: bytes, iv16: bytes, plaintext: bytes) -> str:
    ciphertext = openssl_aes_cbc_encrypt(key32, iv16, plaintext)
    return "0.{}|{}".format(
        base64.b64encode(iv16).decode("ascii"),
        base64.b64encode(ciphertext).decode("ascii"),
    )


def generate_rsa_material(user_key: bytes, org_key: bytes, rsa_dir: pathlib.Path):
    rsa_dir.mkdir(parents=True, exist_ok=True)
    pem = rsa_dir / "vsq-canary-rsa.pem"
    if not pem.exists():
        subprocess.run(
            [
                "openssl", "genpkey", "-algorithm", "RSA",
                "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(pem),
            ],
            check=True,
            capture_output=True,
        )
    # `openssl pkey -outform DER` emits a traditional PKCS#1 RSAPrivateKey on
    # OpenSSL 3.x; the Swift DER reader expects the PKCS#8 PrivateKeyInfo
    # envelope, so ask for it explicitly.
    pkcs8_der = subprocess.run(
        ["openssl", "pkcs8", "-topk8", "-nocrypt",
         "-in", str(pem), "-outform", "DER"],
        check=True,
        capture_output=True,
    ).stdout
    spki_der = subprocess.run(
        ["openssl", "pkey", "-in", str(pem), "-pubout", "-outform", "DER"],
        check=True,
        capture_output=True,
    ).stdout
    with tempfile.TemporaryDirectory() as tmp:
        org_path = pathlib.Path(tmp) / "org.bin"
        enc_path = pathlib.Path(tmp) / "org.enc"
        org_path.write_bytes(org_key)
        subprocess.run(
            [
                "openssl", "pkeyutl", "-encrypt", "-inkey", str(pem),
                "-pkeyopt", "rsa_padding_mode:oaep",
                "-pkeyopt", "rsa_oaep_md:sha1",
                "-in", str(org_path), "-out", str(enc_path),
            ],
            check=True,
        )
        wrapped_org = enc_path.read_bytes()
    return pkcs8_der, spki_der, wrapped_org


def emit_swift(values: dict) -> str:
    lines = [
        "// Generated by scripts/generate-crypto-fixtures.py",
        f"// Recipe revision {RECIPE_REVISION}. Do not edit by hand; regenerate and",
        "// re-review instead. All values are synthetic VSQ-Canary fixture data",
        "// (ADR 0005): no production or provider-derived material exists here.",
        "// RSA members are not byte-regenerable (OAEP is randomized); every other",
        "// member is deterministic from the recipe.",
        "",
        "enum VaultwardenCryptoFixtures {",
    ]
    for name, value in values.items():
        if isinstance(value, str):
            lines.append(f'    static let {name} = "{value}"')
        elif isinstance(value, bytes):
            lines.append(f'    static let {name} = "{value.hex()}"')
        elif isinstance(value, list):
            lines.append(f"    static let {name} = [")
            for entry in value:
                fields = ", ".join(
                    f'{key}: {val}' if isinstance(val, int)
                    else f'{key}: "{val.hex() if isinstance(val, bytes) else val}"'
                    for key, val in entry.items()
                )
                lines.append(f"        ({fields}),")
            lines.append("    ]")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="VaultSquireTests/VaultwardenCryptoFixtures.swift")
    parser.add_argument(
        "--rsa-dir",
        default=str(pathlib.Path(tempfile.gettempdir()) / "vsq-fixture-rsa"),
        help="Directory holding the reusable synthetic RSA key PEM; kept "
             "outside the repository so no PEM private-key block is ever "
             "committed (the committed DER hex is synthetic fixture data)",
    )
    parser.add_argument("--check", action="store_true",
                        help="Verify the committed file matches this recipe")
    args = parser.parse_args()

    email_norm = normalized_email(EMAIL_RAW)
    pbkdf2_cases = []
    for iterations in PBKDF2_ITERATION_CASES:
        master = derive_master_key(PASSWORD, EMAIL_RAW, iterations)
        pbkdf2_cases.append({
            "iterations": iterations,
            "masterKeyHex": master,
            "authHashBase64": auth_hash(master, PASSWORD),
        })
    padded_master = derive_master_key(PASSWORD_WHITESPACE, EMAIL_RAW, 100000)

    master_key = derive_master_key(PASSWORD, EMAIL_RAW, 100000)
    stretched = stretch_master_key(master_key)

    user_key = deterministic_bytes("user-key", 64)
    user_key_iv = deterministic_bytes("user-key-iv", 16)
    wrapped_user_key = enc_string_type2(stretched, user_key_iv, user_key)

    item_iv = deterministic_bytes("item-iv", 16)
    item_enc_string = enc_string_type2(
        user_key, item_iv, ITEM_PLAINTEXT.encode("utf-8")
    )

    legacy_iv = deterministic_bytes("legacy-iv", 16)
    legacy32 = enc_string_type0(
        master_key, legacy_iv, deterministic_bytes("legacy-user-key-32", 32)
    )
    legacy64 = enc_string_type0(
        master_key, legacy_iv, deterministic_bytes("legacy-user-key-64", 64)
    )

    org_key = deterministic_bytes("org-key", 64)
    pkcs8_der, spki_der, wrapped_org = generate_rsa_material(
        user_key, org_key, pathlib.Path(args.rsa_dir)
    )
    org_item_iv = deterministic_bytes("org-item-iv", 16)
    org_item_enc_string = enc_string_type2(
        org_key, org_item_iv, b"VSQ-Canary-org-item-plaintext"
    )

    values = {
        "emailRaw": EMAIL_RAW,
        "emailNormalized": email_norm,
        "password": PASSWORD,
        "passwordWhitespace": PASSWORD_WHITESPACE,
        "paddedPasswordMasterKeyHex": padded_master,
        "pbkdf2Cases": pbkdf2_cases,
        "stretchedMasterKeyHex": stretched,
        "userKeyHex": user_key,
        "wrappedUserKey": wrapped_user_key,
        "itemPlaintext": ITEM_PLAINTEXT,
        "itemEncString": item_enc_string,
        "legacyType0UserKey32": legacy32,
        "legacyType0UserKey64": legacy64,
        "rsaPrivateKeyPkcs8Hex": pkcs8_der,
        "rsaPublicKeySpkiHex": spki_der,
        "orgKeyHex": org_key,
        "wrappedOrgKeyHex": wrapped_org,
        "orgItemEncString": org_item_enc_string,
    }

    swift = emit_swift(values)
    output_path = pathlib.Path(args.output)
    if args.check:
        committed = output_path.read_text()
        # RSA members and their dependents are not regenerable; compare only
        # deterministic lines.
        deterministic = [
            line for line in swift.splitlines()
            if not any(k in line for k in ("rsa", "wrappedOrgKeyHex"))
        ]
        for line in deterministic:
            if line and line not in committed:
                print(f"MISMATCH: {line[:100]}", file=sys.stderr)
                return 1
        print("Deterministic fixture sections match the recipe.")
        return 0

    output_path.write_text(swift)
    digest = hashlib.sha256(swift.encode("utf-8")).hexdigest()
    print(f"Wrote {output_path} (SHA-256 {digest})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
