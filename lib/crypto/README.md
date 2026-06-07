# Bux Crypto Library (`Std::Crypto`)

Cryptographic primitives for the Bux programming language. Backed by OpenSSL via the C runtime (`rt/runtime.c`).

## Modules

| Module | Import Path | Provides |
|--------|------------|----------|
| **Base64** | `Std::Crypto::Base64` | Base64 and Base64URL (RFC 4648 §5) encode/decode |
| **Hash** | `Std::Crypto::Hash` | SHA-1, SHA-256, SHA-384, SHA-512 (hex + raw) |
| **HMAC** | `Std::Crypto::Hmac` | HMAC-SHA256, HMAC-SHA384, HMAC-SHA512 (hex + raw + base64) |
| **Random** | `Std::Crypto::Random` | Cryptographically secure random bytes, hex, base64, uint32 |
| **AES** | `Std::Crypto::Aes` | AES-256-CBC and AES-256-GCM encrypt/decrypt |
| **RSA** | `Std::Crypto::Rsa` | RSA PKCS#1 v1.5 sign/verify (SHA-256/384/512) |
| **ECDSA** | `Std::Crypto::Ecdsa` | ECDSA P-256 and P-384 sign/verify |
| **Ed25519** | `Std::Crypto::Ed25519` | Ed25519 key generation, signing, verification |
| **JWT** | `Std::Crypto::Jwt` | JSON Web Tokens (HS256/384/512, RS256/384/512, ES256/384, EdDSA) |

The legacy `Std::Crypto` module (the old single-file API) is preserved as a backward-compatible wrapper — existing code continues to work.

## Quick Start

### Hash

```bux
import Std::Crypto::Hash::{Hash_Sha256, Hash_Sha384, Hash_Sha512};

let hex: String = Hash_Sha256("hello");
// → "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

let size: int = Hash_Sha256Size(); // → 32 (bytes)
```

### HMAC

```bux
import Std::Crypto::Hmac::{Hmac_Sha256, Hmac_Sha256Raw, Hmac_Sha256Base64};

let hex: String = Hmac_Sha256("secret-key", "message");
// → hex string

// Raw binary output (caller allocates 32-byte buffer)
let buf: *void = Alloc(32);
Hmac_Sha256Raw("secret-key", "message", buf);
// buf now contains 32 bytes of raw HMAC

let b64: String = Hmac_Sha256Base64("secret-key", "message");
// → base64-encoded HMAC
```

### Base64 & Base64URL

```bux
import Std::Crypto::Base64::{Base64_Encode, Base64_Decode,
                              Base64URL_Encode, Base64URL_Decode};

let std: String = Base64_Encode("hello");     // → "aGVsbG8="
let orig: String = Base64_Decode(std);        // → "hello"

let url: String = Base64URL_Encode("hello");  // → "aGVsbG8" (no padding)
let orig2: String = Base64URL_Decode(url);    // → "hello"
```

### Random

```bux
import Std::Crypto::Random::{Random_Bytes, Random_Hex, Random_Base64, Random_Uint32};

let raw: String = Random_Bytes(32);   // 32 random bytes (binary-safe string)
let hex: String = Random_Hex(16);     // 16 random bytes as hex (32 chars)
let b64: String = Random_Base64(16);  // 16 random bytes as base64
let u32: uint = Random_Uint32();      // random 32-bit unsigned integer
```

### AES-256

```bux
import Std::Crypto::Aes::{Aes_GenerateKey, Aes_GenerateIV,
                           Aes_CbcEncrypt, Aes_CbcDecrypt,
                           Aes_GcmEncrypt, Aes_GcmDecrypt};

// Generate random key and IV
let key: String = Aes_GenerateKey();  // 32 raw bytes
let iv: String  = Aes_GenerateIV();   // 16 raw bytes

// CBC mode
let cipher: String = Aes_CbcEncrypt("secret message", key, iv);
let plain: String  = Aes_CbcDecrypt(cipher, key, iv);

// GCM mode (authenticated encryption)
let tag: *void = Alloc(16);
let gcmCipher: String = Aes_GcmEncrypt("secret", key, iv, tag);
let gcmPlain: String  = Aes_GcmDecrypt(gcmCipher, key, iv, tag as String);
```

### RSA

```bux
import Std::Crypto::Rsa::{Rsa_SignSha256, Rsa_VerifySha256,
                           Rsa_SignSha256Base64, Rsa_VerifySha256Base64};

// Keys are PEM-encoded strings
let pemPriv: String = ReadFile("private.pem");
let pemPub: String  = ReadFile("public.pem");

// Sign — returns raw signature
let sig: String = Rsa_SignSha256(pemPriv, "data to sign");

// Or sign and get base64
let sigB64: String = Rsa_SignSha256Base64(pemPriv, "data to sign");

// Verify raw signature
let valid: bool = Rsa_VerifySha256(pemPub, "data to sign", sig);

// Verify base64 signature
let validB64: bool = Rsa_VerifySha256Base64(pemPub, "data to sign", sigB64);
```

### ECDSA

```bux
import Std::Crypto::Ecdsa::{Ecdsa_SignP256, Ecdsa_VerifyP256,
                             Ecdsa_SignP384, Ecdsa_VerifyP384};

// P-256 (ES256)
let sig: String = Ecdsa_SignP256(pemPriv, "data");
let ok: bool = Ecdsa_VerifyP256(pemPub, "data", sig);

// P-384 (ES384)
let sig384: String = Ecdsa_SignP384(pemPriv, "data");
let ok384: bool = Ecdsa_VerifyP384(pemPub, "data", sig384);
```

### Ed25519

```bux
import Std::Crypto::Ed25519::{Ed25519_Keypair, Ed25519_Sign, Ed25519_Verify};

// Generate keypair — keys are 32 raw bytes each
let pub: *void = Alloc(32);
let priv: *void = Alloc(32);
Ed25519_Keypair(pub, priv);

// Sign
let sig: String = Ed25519_Sign(priv as String, "message");
// sig is 64 raw bytes

// Verify
let valid: bool = Ed25519_Verify(pub as String, sig, "message");
```

### JWT

```bux
import Std::Crypto::Jwt::{JwtAlg, Jwt_MakeHeader, Jwt_Encode,
                           Jwt_Decode, Jwt_EncodeHS256};

// --- Symmetric (HS256) ---
let token: String = Jwt_EncodeHS256("{\"sub\":\"123\",\"role\":\"admin\"}", "my-secret");

var header: String;
var payload: String;
let alg: JwtAlg = JwtAlg { tag: JwtAlg_HS256 };
if Jwt_Decode(token, alg, "my-secret", &header, &payload) {
    PrintLine(payload);  // {"sub":"123","role":"admin"}
}

// --- Asymmetric (RS256) ---
let rsToken: String = Jwt_Encode(
    "{\"alg\":\"RS256\",\"typ\":\"JWT\"}",
    "{\"sub\":\"456\"}",
    JwtAlg { tag: JwtAlg_RS256 },
    pemPrivateKey
);

// --- Convenience helpers ---
Jwt_EncodeHS256(payload, secret);
Jwt_EncodeHS384(payload, secret);
Jwt_EncodeHS512(payload, secret);
Jwt_EncodeRS256(payload, pemPrivKey);
Jwt_EncodeES256(payload, pemPrivKey);
Jwt_EncodeEdDSA(payload, rawPrivKey32);
```

## Supported JWT Algorithms

| Algorithm | JWT `alg` | Key Type | Key Format |
|-----------|-----------|----------|------------|
| HS256 | `HS256` | HMAC secret | Raw string |
| HS384 | `HS384` | HMAC secret | Raw string |
| HS512 | `HS512` | HMAC secret | Raw string |
| RS256 | `RS256` | RSA private/public key | PEM string |
| RS384 | `RS384` | RSA private/public key | PEM string |
| RS512 | `RS512` | RSA private/public key | PEM string |
| ES256 | `ES256` | ECDSA P-256 key | PEM string |
| ES384 | `ES384` | ECDSA P-384 key | PEM string |
| EdDSA | `EdDSA` | Ed25519 key | 32-byte raw |

## Backend

All primitives are implemented in C using OpenSSL and linked via the Bux runtime (`rt/runtime.c`). The C functions are declared as `extern func` in each Bux module.

Requires OpenSSL 1.1.1+ (for Ed25519 support). Link with `-lssl -lcrypto`.

## File Layout

```
lib/
├── Crypto.bux              # Backward-compat wrapper (old API)
└── crypto/
    ├── base64.bux           # Base64 + Base64URL
    ├── hash.bux             # SHA-1/256/384/512
    ├── hmac.bux             # HMAC-SHA256/384/512
    ├── random.bux           # Secure random
    ├── aes.bux              # AES-256-CBC/GCM
    ├── rsa.bux              # RSA PKCS#1 v1.5
    ├── ecdsa.bux            # ECDSA P-256/P-384
    ├── ed25519.bux          # Ed25519
    └── jwt.bux              # JSON Web Tokens

lib/crypto_test/             # Test project (exercises all modules)
test_crypto/                 # Standalone test project
```

## Migration from old `Std::Crypto`

The old single-file API is still available under `Std::Crypto`:

| Old Function | New Equivalent | Module |
|-------------|----------------|--------|
| `Crypto_Sha256(s)` | `Hash_Sha256(s)` | `Std::Crypto::Hash` |
| `Crypto_HmacSha256(k, m)` | `Hmac_Sha256(k, m)` | `Std::Crypto::Hmac` |
| `Crypto_RandomBytes(n)` | `Random_Base64(n)` | `Std::Crypto::Random` |
| `Crypto_Base64Encode(s)` | `Base64_Encode(s)` | `Std::Crypto::Base64` |
| `Crypto_Base64Decode(s)` | `Base64_Decode(s)` | `Std::Crypto::Base64` |
| `Crypto_HmacSha256Raw(k, m)` | `Hmac_Sha256Base64(k, m)` | `Std::Crypto::Hmac` |

New code should prefer the submodule imports for clarity and to avoid pulling in unused declarations.

## Running Tests

```bash
cd test_crypto
../buxc build
./test_crypto
```

Expected output:
```
================================================
  Bux Crypto Library — Test Suite
================================================

--- Base64 ---
  PASS Base64_Encode('hello')
  PASS Base64_Decode('aGVsbG8=')
  ...
--- Hash ---
  PASS Hash_Sha256('hello')
  ...
================================================
  Passed: 23
  Failed: 0
================================================
```
