# jwt-pitbul

**JWT CLI tool for the Bux ecosystem — sign, verify, decode, and key generation.**

A standalone command-line utility for working with JSON Web Tokens (RFC 7519). Built on `Std::Crypto`, backed by OpenSSL.

This version (0.2.0) is rewritten with modern Bux: algebraic enums, generic `Array<String>`, methods on `JwtAlg`, string interpolation, `for` loops, and structured `Result`/`Option`-style error handling.

## Quick Start

```bash
cd apps/jwt-pitbul
../../buxc build
./build/jwt-pitbul
```

## Commands

### `sign` — Create a JWT

```
jwt-pitbul sign <alg> <key> <claims_json>
```

| Argument | Description |
|----------|-------------|
| `<alg>` | Algorithm: `HS256`, `HS384`, `HS512`, `RS256`, `RS384`, `RS512`, `ES256`, `ES384`, `EdDSA` |
| `<key>` | HMAC secret string, or path to PEM file (RSA/ECDSA), or base64 raw key (Ed25519) |
| `<claims_json>` | JSON payload string (e.g. `{"sub":"123","exp":1735689600}`) |

```bash
# HMAC
jwt-pitbul sign HS256 'my-secret-key' '{"sub":"123","role":"admin"}'

# RSA (private key from file)
jwt-pitbul sign RS256 private.pem '{"sub":"456"}'

# ECDSA
jwt-pitbul sign ES256 ec_private.pem '{"sub":"789"}'

# Ed25519 (base64-encoded 32-byte private key)
jwt-pitbul sign EdDSA 'MC4CAQAwBQYDK2VwBCIEIJ...' '{"sub":"000"}'
```

### `verify` — Verify and decode

```
jwt-pitbul verify <token> <alg> <key>
```

```bash
jwt-pitbul verify eyJhbGciOiJ... HS256 'my-secret-key'
# ✓ Signature valid
#
# Header:
# {"alg":"HS256","typ":"JWT"}
#
# Payload:
# {"sub":"123","role":"admin"}
```

### `decode` — Decode without verification

```
jwt-pitbul decode <token>
```

```bash
jwt-pitbul decode eyJhbGciOiJ...
# Decoded (no verification):
#
# Header:
# {"alg":"HS256","typ":"JWT"}
#
# Payload:
# {"sub":"123"}
#
# Signature (base64url): xxxxxxxxx...
```

### `keygen` — Generate keys

```
jwt-pitbul keygen <type>
```

| Type | Output |
|------|--------|
| `ed25519` | Generates an Ed25519 keypair (prints base64 public/private keys) |
| `rsa` | Prints OpenSSL CLI commands to generate RSA 2048-bit keys |
| `ecdsa` | Prints OpenSSL CLI commands to generate ECDSA P-256 keys |

```bash
jwt-pitbul keygen ed25519
# Ed25519 keypair (base64):
#   Public:  MCowBQYDK2VwAyEA...
#   Private: MC4CAQAwBQYDK2VwBCIEIJ...

jwt-pitbul keygen rsa
# RSA key generation requires OpenSSL CLI:
#   openssl genpkey -algorithm RSA -out private.pem -pkeyopt rsa_keygen_bits:2048
#   openssl rsa -in private.pem -pubout -out public.pem
```

## Supported Algorithms

| Algorithm | Type | Key Format |
|-----------|------|------------|
| HS256 | HMAC-SHA256 | Raw secret string |
| HS384 | HMAC-SHA384 | Raw secret string |
| HS512 | HMAC-SHA512 | Raw secret string |
| RS256 | RSA PKCS#1 v1.5 SHA-256 | PEM file path |
| RS384 | RSA PKCS#1 v1.5 SHA-384 | PEM file path |
| RS512 | RSA PKCS#1 v1.5 SHA-512 | PEM file path |
| ES256 | ECDSA P-256 | PEM file path |
| ES384 | ECDSA P-384 | PEM file path |
| EdDSA | Ed25519 | Base64 32-byte raw key |

## Generating Keys with OpenSSL

### RSA 2048-bit

```bash
openssl genpkey -algorithm RSA -out private.pem -pkeyopt rsa_keygen_bits:2048
openssl rsa -in private.pem -pubout -out public.pem
```

### ECDSA P-256

```bash
openssl ecparam -genkey -name prime256v1 -noout -out ec_private.pem
openssl ec -in ec_private.pem -pubout -out ec_public.pem
```

### ECDSA P-384

```bash
openssl ecparam -genkey -name secp384r1 -noout -out ec_private.pem
openssl ec -in ec_private.pem -pubout -out ec_public.pem
```

### Ed25519

```bash
# In-app generation:
jwt-pitbul keygen ed25519

# Or via OpenSSL:
openssl genpkey -algorithm Ed25519 -out ed25519_private.pem
openssl pkey -in ed25519_private.pem -pubout -out ed25519_public.pem
```

## Error Codes

| Exit | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error (invalid arguments, bad signature, missing file, etc.) |

## Building

```bash
cd apps/jwt-pitbul
../../buxc build      # Bootstrap compiler (Nim)
# or
../../buxc_lir build  # Self-hosted compiler
```

## Dependencies

- Bux standard library (`Std::Crypto`, `Std::Io`, `Std::String`)
- OpenSSL 1.1.1+ (linked via runtime)
- Bux compiler (`buxc` or `buxc_lir`)

## License

Part of the Bux project. See root [LICENSE](../../LICENSE).
