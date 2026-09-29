# AZ3166 signed OTA host tooling

`az3166-ota` is an installable Python package and command-line tool for the
Core `AZPKG001` signed OTA format. It parses `AZOTA001` descriptors, validates
raw AZ3166 application images, builds P-256/SHA-256 packages, and verifies
packages before transport-specific code uses them.

The package deliberately has no product or repository policy. Product ID,
board ID, version policy, signing-key approval, key storage, upload transport,
and activation policy belong to the consuming application. Optional CLI
expectations let automation enforce those values without embedding defaults in
this tool.

## Install

Python 3.10 or newer is required. Installation resolves the deliberately pinned
`cryptography==50.0.1` dependency:

```powershell
python -m pip install .\tools\ota
az3166-ota --help
```

For editable development:

```powershell
python -m pip install -e .\tools\ota
python -m unittest discover -s .\tools\ota\tests -v
python -m compileall -q .\tools\ota\src .\tools\ota\tests
```

## Generate a signing key

Generate an unencrypted P-256 PKCS#8 PEM private key and its canonical RFC 5480
DER SubjectPublicKeyInfo:

```powershell
az3166-ota generate-key `
  --private-key C:\secure\az3166-signing.pem `
  --public-key C:\secure\az3166-signing-public.der
```

Both parent directories must already exist. `--create-parents` explicitly
permits creating missing parents. Existing paths are refused; `--force`
explicitly replaces them. Destinations that resolve to the same file through a
symlink, junction, parent alias, or hard link are rejected. Each file is written
and flushed in its destination directory before publication. Pair publication
retains rollback links for existing outputs: if either publication fails, both
old files are restored, or both newly created outputs are removed. If the file
system also prevents restoration, the error reports the exact destination and
retained backup path for manual recovery; that backup is never cleaned up by
the failed operation. The private file is requested with owner-only permissions
on systems that implement POSIX modes.

Output is JSON containing the lowercase SHA-256 key ID, public-key hash, and
the two paths. Private bytes and private scalar values are never printed.
Protect, back up, and approve private keys according to the consuming
application's policy.

## Validate, build, and verify

The raw image must contain its 256-byte `AZOTA001` descriptor at offset `0x200`.
Its key ID is SHA-256 of the canonical public DER.

```powershell
az3166-ota validate-image `
  --image .\application.bin `
  --public-key C:\secure\az3166-signing-public.der

az3166-ota build `
  --image .\application.bin `
  --private-key C:\secure\az3166-signing.pem `
  --output .\application.azpkg

az3166-ota verify `
  --package .\application.azpkg `
  --public-key C:\secure\az3166-signing-public.der
```

Use any of `--product`, `--board`, `--version`, `--source`, `--address`, and
`--capacity` to require policy values in addition to strict format checks:

```powershell
az3166-ota verify `
  --package .\application.azpkg `
  --public-key C:\secure\az3166-signing-public.der `
  --product ExampleProduct `
  --board MXCHIP_AZ3166 `
  --version 1.2.3 `
  --source 0123456789abcdef0123456789abcdef01234567 `
  --address 0x0800c000 `
  --capacity 0x000f4000
```

The verifier checks fixed fields and lengths, canonical descriptor encoding,
reserved bytes, application bounds, Cortex-M vector values, descriptor/key
binding, header/embedded descriptor equality, payload SHA-256, and the raw
big-endian P-256 `r || s` signature.

## Format and compatibility vector

Core format version 1 is:

| Offset | Size | Content |
| ---: | ---: | --- |
| 0 | 64 | `AZPKG001` envelope prefix |
| 64 | 256 | exact `AZOTA001` descriptor copy |
| 320 | 64 | P-256 ECDSA/SHA-256 signature as raw `r || s` |
| 384 | variable | raw application image |

The signature covers the 320-byte header. All integer fields are little-endian;
the two signature scalars are unsigned big-endian.

`tests/data/golden-package.azpkg` is a fixed, independently reusable package
with its canonical public key and expected hashes in `golden-vector.json`.
`test_golden_vector.py` verifies those immutable bytes through the Python API,
and the existing C++ `OTAStagingTest` streams the same package through the Core
consumer to independently validate its envelope, descriptor, key binding,
vectors, payload digest, and Flash read-back. The vector is not a production
signing identity.

The host tooling is intentionally excluded from
`platform/az3166/package-layout.json`, so adding or changing it does not alter
the published Arduino platform archives.
