from __future__ import annotations

import hashlib
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cryptography.exceptions import UnsupportedAlgorithm
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

from az3166_ota.package import (
    DESCRIPTOR_OFFSET,
    DESCRIPTOR_SIZE,
    PACKAGE_HEADER_SIZE,
    PAYLOAD_OFFSET,
    PackageError,
    build_package,
    load_private_key,
    load_public_key,
    parse_descriptor,
    public_key_der,
    validate_raw_image,
    verify_package,
)

PRODUCT = "ExampleProduct"
BOARD = "MXCHIP_AZ3166"
VERSION = "12.34.56"
SOURCE = "0123456789abcdef0123456789abcdef01234567"
ADDRESS = 0x0800C000
CAPACITY = 0x000F4000


def _field(value: str, size: int) -> bytes:
    encoded = value.encode("ascii")
    return encoded + bytes(size - len(encoded))


def make_image(public_der: bytes) -> bytes:
    image = bytearray(0x400)
    struct.pack_into("<II", image, 0, 0x20001000, ADDRESS + 0x101)
    descriptor = bytearray(DESCRIPTOR_SIZE)
    descriptor[:8] = b"AZOTA001"
    struct.pack_into("<HHI", descriptor, 8, 1, DESCRIPTOR_SIZE, 1)
    descriptor[16:48] = _field(PRODUCT, 32)
    descriptor[48:80] = _field(BOARD, 32)
    descriptor[80:112] = _field(VERSION, 32)
    descriptor[112:152] = SOURCE.encode("ascii")
    struct.pack_into("<III", descriptor, 152, ADDRESS, CAPACITY, 1)
    descriptor[164:196] = hashlib.sha256(public_der).digest()
    image[DESCRIPTOR_OFFSET : DESCRIPTOR_OFFSET + DESCRIPTOR_SIZE] = descriptor
    return bytes(image)


class PackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.private_key = ec.derive_private_key(
            0x123456789ABCDEF123456789ABCDEF123456789ABCDEF123456789ABCDEF,
            ec.SECP256R1(),
        )
        self.public_der = public_key_der(self.private_key)
        self.public_key = self.private_key.public_key()
        self.image = make_image(self.public_der)
        self.expected = {
            "expected_product": PRODUCT,
            "expected_board": BOARD,
            "expected_version": VERSION,
            "expected_source": SOURCE,
            "expected_address": ADDRESS,
            "expected_capacity": CAPACITY,
        }
        self.package = build_package(self.image, self.private_key, **self.expected)

    def verify(self, package: bytes | None = None):
        return verify_package(
            self.package if package is None else package,
            self.public_key,
            self.public_der,
            **self.expected,
        )

    def test_builds_and_verifies_generic_package(self) -> None:
        verified = self.verify()
        self.assertEqual(verified.descriptor.product_id, PRODUCT)
        self.assertEqual(verified.payload_length, len(self.image))
        self.assertEqual(verified.payload_sha256, hashlib.sha256(self.image).digest())

    def test_parses_descriptor_without_product_defaults(self) -> None:
        parsed = parse_descriptor(
            self.image[DESCRIPTOR_OFFSET : DESCRIPTOR_OFFSET + DESCRIPTOR_SIZE]
        )
        self.assertEqual((parsed.product_id, parsed.board_id), (PRODUCT, BOARD))

    def test_validates_image_without_optional_policy_expectations(self) -> None:
        descriptor = validate_raw_image(
            self.image, key_id=hashlib.sha256(self.public_der).digest()
        )
        self.assertEqual(descriptor.application_address, ADDRESS)

    def test_rejects_every_envelope_integrity_layer(self) -> None:
        mutations = (
            (0, "magic"),
            (20, "SHA-256"),
            (PACKAGE_HEADER_SIZE, "signature"),
            (PAYLOAD_OFFSET + DESCRIPTOR_OFFSET, "descriptor"),
            (len(self.package) - 1, "SHA-256"),
        )
        for offset, message in mutations:
            with self.subTest(offset=offset):
                package = bytearray(self.package)
                package[offset] ^= 1
                with self.assertRaisesRegex(PackageError, message):
                    self.verify(bytes(package))

    def test_rejects_invalid_raw_signature_scalars(self) -> None:
        for signature in (bytes(64), bytes([0xFF]) * 64):
            with self.subTest(signature=signature[:1]):
                package = bytearray(self.package)
                package[PACKAGE_HEADER_SIZE:PAYLOAD_OFFSET] = signature
                with self.assertRaisesRegex(PackageError, "signature"):
                    self.verify(bytes(package))

    def test_rejects_wrong_verification_key(self) -> None:
        wrong = ec.generate_private_key(ec.SECP256R1())
        wrong_der = public_key_der(wrong)
        with self.assertRaisesRegex(PackageError, "identifier"):
            verify_package(self.package, wrong.public_key(), wrong_der)

    def test_rejects_mismatched_key_object_and_der(self) -> None:
        wrong_der = public_key_der(ec.generate_private_key(ec.SECP256R1()))
        with self.assertRaisesRegex(PackageError, "does not match"):
            verify_package(self.package, self.public_key, wrong_der)

    def test_rejects_non_p256_keys(self) -> None:
        with self.assertRaisesRegex(PackageError, "P-256"):
            build_package(self.image, ec.generate_private_key(ec.SECP384R1()))
        with self.assertRaisesRegex(PackageError, "P-256"):
            verify_package(
                self.package,
                ec.generate_private_key(ec.SECP384R1()).public_key(),
                self.public_der,
            )

    def test_rejects_bad_vectors_capacity_and_policy(self) -> None:
        bad_vector = bytearray(self.image)
        struct.pack_into("<I", bad_vector, 0, 0x20001004)
        with self.assertRaisesRegex(PackageError, "stack pointer"):
            validate_raw_image(
                bytes(bad_vector), key_id=hashlib.sha256(self.public_der).digest()
            )
        with self.assertRaisesRegex(PackageError, "product"):
            validate_raw_image(
                self.image,
                key_id=hashlib.sha256(self.public_der).digest(),
                expected_product="AnotherProduct",
            )

        small_capacity = bytearray(self.image)
        struct.pack_into("<I", small_capacity, DESCRIPTOR_OFFSET + 156, 0x300)
        with self.assertRaisesRegex(PackageError, "capacity"):
            validate_raw_image(
                bytes(small_capacity), key_id=hashlib.sha256(self.public_der).digest()
            )

    def test_rejects_noncanonical_descriptor_fields(self) -> None:
        cases = (
            (DESCRIPTOR_OFFSET + 16, ord("X"), "padded"),
            (DESCRIPTOR_OFFSET + 196, 1, "reserved"),
            (DESCRIPTOR_OFFSET + 112, ord("G"), "source commit"),
        )
        for offset, value, message in cases:
            with self.subTest(offset=offset):
                image = bytearray(self.image)
                if offset == DESCRIPTOR_OFFSET + 16:
                    image[DESCRIPTOR_OFFSET + 16 : DESCRIPTOR_OFFSET + 48] = (
                        b"X" * 31 + b"\0"
                    )
                    image[DESCRIPTOR_OFFSET + 20] = 0
                else:
                    image[offset] = value
                with self.assertRaisesRegex(PackageError, message):
                    parse_descriptor(
                        bytes(
                            image[
                                DESCRIPTOR_OFFSET : DESCRIPTOR_OFFSET + DESCRIPTOR_SIZE
                            ]
                        )
                    )

    def test_loads_only_canonical_public_and_private_keys(self) -> None:
        private_pem = self.private_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
        private_der = self.private_key.private_bytes(
            serialization.Encoding.DER,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            public_path = root / "public.der"
            private_pem_path = root / "private.pem"
            private_der_path = root / "private.der"
            public_path.write_bytes(self.public_der)
            private_pem_path.write_bytes(private_pem)
            private_der_path.write_bytes(private_der)
            self.assertEqual(load_public_key(public_path)[1], self.public_der)
            self.assertEqual(
                load_private_key(private_pem_path).private_numbers(),
                self.private_key.private_numbers(),
            )
            self.assertEqual(
                load_private_key(private_der_path).private_numbers(),
                self.private_key.private_numbers(),
            )

            private_pem_path.write_bytes(private_pem.replace(b"\n", b"\r\n"))
            with self.assertRaisesRegex(PackageError, "canonical"):
                load_private_key(private_pem_path)
            public_path.write_bytes(
                self.public_key.public_bytes(
                    serialization.Encoding.X962,
                    serialization.PublicFormat.UncompressedPoint,
                )
            )
            with self.assertRaisesRegex(PackageError, "SubjectPublicKeyInfo"):
                load_public_key(public_path)

    def test_translates_unsupported_key_algorithms(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            public_path = root / "public.der"
            private_path = root / "private.pem"
            public_path.write_bytes(b"unsupported public key")
            private_path.write_bytes(
                b"-----BEGIN PRIVATE KEY-----\nunsupported\n"
                b"-----END PRIVATE KEY-----\n"
            )
            with patch(
                "az3166_ota.package.serialization.load_der_public_key",
                side_effect=UnsupportedAlgorithm("unsupported"),
            ):
                with self.assertRaisesRegex(PackageError, "public key"):
                    load_public_key(public_path)
            with patch(
                "az3166_ota.package.serialization.load_pem_private_key",
                side_effect=UnsupportedAlgorithm("unsupported"),
            ):
                with self.assertRaisesRegex(PackageError, "private key"):
                    load_private_key(private_path)

    def test_header_signature_is_raw_big_endian_rs(self) -> None:
        raw = self.package[PACKAGE_HEADER_SIZE:PAYLOAD_OFFSET]
        r = int.from_bytes(raw[:32], "big")
        s = int.from_bytes(raw[32:], "big")
        der = self.private_key.sign(
            self.package[:PACKAGE_HEADER_SIZE], ec.ECDSA(hashes.SHA256())
        )
        sample_r, sample_s = decode_dss_signature(der)
        self.assertGreater(r, 0)
        self.assertGreater(s, 0)
        self.assertGreater(sample_r, 0)
        self.assertGreater(sample_s, 0)

if __name__ == "__main__":
    unittest.main()
