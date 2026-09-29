from __future__ import annotations

import hashlib
import re
import struct
from dataclasses import dataclass
from pathlib import Path

from cryptography.exceptions import InvalidSignature, UnsupportedAlgorithm
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import (
    decode_dss_signature,
    encode_dss_signature,
)

PACKAGE_MAGIC = b"AZPKG001"
DESCRIPTOR_MAGIC = b"AZOTA001"
PACKAGE_PREFIX_SIZE = 64
DESCRIPTOR_OFFSET = 0x200
DESCRIPTOR_SIZE = 256
PACKAGE_HEADER_SIZE = PACKAGE_PREFIX_SIZE + DESCRIPTOR_SIZE
SIGNATURE_SIZE = 64
PAYLOAD_OFFSET = PACKAGE_HEADER_SIZE + SIGNATURE_SIZE
PACKAGE_FORMAT_VERSION = 1
DESCRIPTOR_FORMAT_VERSION = 1
SIGNATURE_ALGORITHM = 1
SECURITY_PROFILE = 1
RAM_START_EXCLUSIVE = 0x200001C4
RAM_END_INCLUSIVE = 0x20040000

_VERSION_PATTERN = re.compile(
    r"(?:0|[1-9][0-9]{0,4})\.(?:0|[1-9][0-9]{0,4})\.(?:0|[1-9][0-9]{0,4})\Z"
)
_SOURCE_PATTERN = re.compile(r"[0-9a-f]{40}\Z")


class PackageError(ValueError):
    """The key, raw image, descriptor, or package is invalid."""


@dataclass(frozen=True)
class Descriptor:
    product_id: str
    board_id: str
    firmware_version: str
    source_commit: str
    application_address: int
    application_capacity: int
    key_id: bytes


@dataclass(frozen=True)
class VerifiedPackage:
    descriptor: Descriptor
    payload_length: int
    payload_sha256: bytes


def _canonical_string(field: bytes, name: str) -> str:
    try:
        terminator = field.index(0)
    except ValueError as error:
        raise PackageError(f"{name} is not NUL-terminated") from error
    if terminator == 0 or any(field[terminator + 1 :]):
        raise PackageError(f"{name} is not canonically padded")
    try:
        return field[:terminator].decode("ascii")
    except UnicodeDecodeError as error:
        raise PackageError(f"{name} is not ASCII") from error


def _validate_version(version: str) -> None:
    if _VERSION_PATTERN.fullmatch(version) is None:
        raise PackageError("firmware version must be canonical MAJOR.MINOR.PATCH")
    if any(int(component) > 65535 for component in version.split(".")):
        raise PackageError("firmware version components must not exceed 65535")


def parse_descriptor(data: bytes) -> Descriptor:
    """Parse and strictly validate one AZOTA001 compatibility descriptor."""
    if len(data) != DESCRIPTOR_SIZE:
        raise PackageError("descriptor must be exactly 256 bytes")
    if data[:8] != DESCRIPTOR_MAGIC:
        raise PackageError("invalid descriptor magic")
    descriptor_version, descriptor_size = struct.unpack_from("<HH", data, 8)
    security_profile = struct.unpack_from("<I", data, 12)[0]
    package_version = struct.unpack_from("<I", data, 160)[0]
    if (
        descriptor_version != DESCRIPTOR_FORMAT_VERSION
        or descriptor_size != DESCRIPTOR_SIZE
        or security_profile != SECURITY_PROFILE
        or package_version != PACKAGE_FORMAT_VERSION
    ):
        raise PackageError("unsupported descriptor format")
    if any(data[196:]):
        raise PackageError("descriptor reserved bytes must be zero")

    product_id = _canonical_string(data[16:48], "product ID")
    board_id = _canonical_string(data[48:80], "board ID")
    firmware_version = _canonical_string(data[80:112], "firmware version")
    _validate_version(firmware_version)
    try:
        source_commit = data[112:152].decode("ascii")
    except UnicodeDecodeError as error:
        raise PackageError("source commit is not ASCII") from error
    if _SOURCE_PATTERN.fullmatch(source_commit) is None:
        raise PackageError("source commit must be 40 lowercase hexadecimal characters")

    application_address, application_capacity = struct.unpack_from("<II", data, 152)
    if application_address & 0x1FF:
        raise PackageError("application address must be aligned to 512 bytes")
    if application_capacity == 0:
        raise PackageError("application capacity must be greater than zero")
    if application_address + application_capacity >= 0x1_0000_0000:
        raise PackageError("application address and capacity overflow")
    return Descriptor(
        product_id=product_id,
        board_id=board_id,
        firmware_version=firmware_version,
        source_commit=source_commit,
        application_address=application_address,
        application_capacity=application_capacity,
        key_id=data[164:196],
    )


def load_public_key(path: Path) -> tuple[ec.EllipticCurvePublicKey, bytes]:
    """Load a canonical RFC 5480 DER P-256 SubjectPublicKeyInfo."""
    encoded = path.read_bytes()
    try:
        key = serialization.load_der_public_key(encoded)
    except (TypeError, ValueError, UnsupportedAlgorithm) as error:
        raise PackageError("public key must be DER SubjectPublicKeyInfo") from error
    if not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(
        key.curve, ec.SECP256R1
    ):
        raise PackageError("public key must use P-256")
    canonical = key.public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    if encoded != canonical:
        raise PackageError("public key must be canonical DER SubjectPublicKeyInfo")
    return key, canonical


def load_private_key(path: Path) -> ec.EllipticCurvePrivateKey:
    """Load a canonical, unencrypted PKCS#8 PEM or DER P-256 private key."""
    encoded = path.read_bytes()
    is_pem = encoded.startswith(b"-----BEGIN PRIVATE KEY-----\n")
    try:
        if is_pem:
            key = serialization.load_pem_private_key(encoded, password=None)
            canonical = key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        else:
            key = serialization.load_der_private_key(encoded, password=None)
            canonical = key.private_bytes(
                serialization.Encoding.DER,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
    except (TypeError, ValueError, UnsupportedAlgorithm) as error:
        raise PackageError(
            "private key must be canonical unencrypted PKCS#8 PEM or DER"
        ) from error
    if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(
        key.curve, ec.SECP256R1
    ):
        raise PackageError("private key must use P-256")
    if encoded != canonical:
        raise PackageError("private key must use canonical unencrypted PKCS#8 encoding")
    return key


def public_key_der(private_key: ec.EllipticCurvePrivateKey) -> bytes:
    if not isinstance(private_key, ec.EllipticCurvePrivateKey) or not isinstance(
        private_key.curve, ec.SECP256R1
    ):
        raise PackageError("private key must use P-256")
    return private_key.public_key().public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    )


def _check_expected(
    descriptor: Descriptor,
    *,
    key_id: bytes,
    expected_product: str | None,
    expected_board: str | None,
    expected_version: str | None,
    expected_source: str | None,
    expected_address: int | None,
    expected_capacity: int | None,
) -> None:
    expected = (
        ("product ID", descriptor.product_id, expected_product),
        ("board ID", descriptor.board_id, expected_board),
        ("firmware version", descriptor.firmware_version, expected_version),
        ("source commit", descriptor.source_commit, expected_source),
        ("application address", descriptor.application_address, expected_address),
        ("application capacity", descriptor.application_capacity, expected_capacity),
    )
    if expected_version is not None:
        _validate_version(expected_version)
    if expected_source is not None and _SOURCE_PATTERN.fullmatch(expected_source) is None:
        raise PackageError("expected source must be 40 lowercase hexadecimal characters")
    for name, actual, wanted in expected:
        if wanted is not None and actual != wanted:
            raise PackageError(f"descriptor {name} does not match")
    if descriptor.key_id != key_id:
        raise PackageError("descriptor signing-key identifier does not match")


def validate_raw_image(
    image: bytes,
    *,
    key_id: bytes,
    expected_product: str | None = None,
    expected_board: str | None = None,
    expected_version: str | None = None,
    expected_source: str | None = None,
    expected_address: int | None = None,
    expected_capacity: int | None = None,
) -> Descriptor:
    """Validate an AZ3166 raw image and return its embedded descriptor."""
    if len(key_id) != 32:
        raise PackageError("key identifier must be exactly 32 bytes")
    if len(image) < DESCRIPTOR_OFFSET + DESCRIPTOR_SIZE:
        raise PackageError("image is too short to contain the descriptor")
    descriptor = parse_descriptor(
        image[DESCRIPTOR_OFFSET : DESCRIPTOR_OFFSET + DESCRIPTOR_SIZE]
    )
    if len(image) > descriptor.application_capacity:
        raise PackageError("image exceeds descriptor application capacity")

    stack_pointer, reset_vector = struct.unpack_from("<II", image, 0)
    if (
        stack_pointer & 7
        or stack_pointer <= RAM_START_EXCLUSIVE
        or stack_pointer > RAM_END_INCLUSIVE
    ):
        raise PackageError("invalid initial stack pointer")
    if reset_vector & 1 == 0:
        raise PackageError("reset vector is not a Thumb address")
    reset_handler = reset_vector & ~1
    image_end = descriptor.application_address + len(image)
    if (
        image_end > 0x1_0000_0000
        or reset_handler < descriptor.application_address
        or reset_handler + 2 > image_end
    ):
        raise PackageError("reset handler is outside the image")

    _check_expected(
        descriptor,
        key_id=key_id,
        expected_product=expected_product,
        expected_board=expected_board,
        expected_version=expected_version,
        expected_source=expected_source,
        expected_address=expected_address,
        expected_capacity=expected_capacity,
    )
    return descriptor


def build_package(
    image: bytes,
    private_key: ec.EllipticCurvePrivateKey,
    **expected: object,
) -> bytes:
    """Validate and sign a raw image as an AZPKG001 package."""
    public_der = public_key_der(private_key)
    key_id = hashlib.sha256(public_der).digest()
    descriptor = validate_raw_image(image, key_id=key_id, **expected)
    descriptor_bytes = image[
        DESCRIPTOR_OFFSET : DESCRIPTOR_OFFSET + DESCRIPTOR_SIZE
    ]
    prefix = struct.pack(
        "<8sHHHHI32s12s",
        PACKAGE_MAGIC,
        PACKAGE_FORMAT_VERSION,
        PACKAGE_HEADER_SIZE,
        SIGNATURE_ALGORITHM,
        SIGNATURE_SIZE,
        len(image),
        hashlib.sha256(image).digest(),
        bytes(12),
    )
    header = prefix + descriptor_bytes
    der_signature = private_key.sign(header, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der_signature)
    signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    if descriptor.key_id != key_id:
        raise PackageError("descriptor key identifier changed during build")
    return header + signature + image


def verify_package(
    package: bytes,
    public_key: ec.EllipticCurvePublicKey,
    public_der: bytes,
    **expected: object,
) -> VerifiedPackage:
    """Strictly verify an AZPKG001 package and its raw application image."""
    if not isinstance(public_key, ec.EllipticCurvePublicKey) or not isinstance(
        public_key.curve, ec.SECP256R1
    ):
        raise PackageError("verification key must use P-256")
    canonical_der = public_key.public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    if canonical_der != public_der:
        raise PackageError("public key DER does not match the verification key")
    if len(package) < PAYLOAD_OFFSET + 1:
        raise PackageError("package is too short")
    (
        magic,
        package_version,
        header_size,
        signature_algorithm,
        signature_size,
        payload_length,
        payload_digest,
        reserved,
    ) = struct.unpack("<8sHHHHI32s12s", package[:PACKAGE_PREFIX_SIZE])
    if magic != PACKAGE_MAGIC:
        raise PackageError("invalid package magic")
    if (
        package_version != PACKAGE_FORMAT_VERSION
        or header_size != PACKAGE_HEADER_SIZE
        or signature_algorithm != SIGNATURE_ALGORITHM
        or signature_size != SIGNATURE_SIZE
    ):
        raise PackageError("unsupported package format")
    if any(reserved):
        raise PackageError("package reserved bytes must be zero")
    if payload_length + PAYLOAD_OFFSET != len(package):
        raise PackageError("package length does not match payload declaration")

    descriptor_bytes = package[PACKAGE_PREFIX_SIZE:PACKAGE_HEADER_SIZE]
    payload = package[PAYLOAD_OFFSET:]
    embedded = payload[
        DESCRIPTOR_OFFSET : DESCRIPTOR_OFFSET + DESCRIPTOR_SIZE
    ]
    if len(embedded) != DESCRIPTOR_SIZE or embedded != descriptor_bytes:
        raise PackageError("embedded descriptor does not match package header")
    descriptor = validate_raw_image(
        payload,
        key_id=hashlib.sha256(public_der).digest(),
        **expected,
    )
    if hashlib.sha256(payload).digest() != payload_digest:
        raise PackageError("payload SHA-256 does not match")

    raw_signature = package[PACKAGE_HEADER_SIZE:PAYLOAD_OFFSET]
    r = int.from_bytes(raw_signature[:32], "big")
    s = int.from_bytes(raw_signature[32:], "big")
    try:
        public_key.verify(
            encode_dss_signature(r, s),
            package[:PACKAGE_HEADER_SIZE],
            ec.ECDSA(hashes.SHA256()),
        )
    except (InvalidSignature, ValueError) as error:
        raise PackageError("package signature is invalid") from error
    return VerifiedPackage(descriptor, payload_length, payload_digest)
