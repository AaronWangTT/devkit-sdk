"""Host tooling for the AZ3166 signed OTA package format."""

from .package import (
    Descriptor,
    PackageError,
    VerifiedPackage,
    build_package,
    load_private_key,
    load_public_key,
    parse_descriptor,
    public_key_der,
    validate_raw_image,
    verify_package,
)

__all__ = [
    "Descriptor",
    "PackageError",
    "VerifiedPackage",
    "build_package",
    "load_private_key",
    "load_public_key",
    "parse_descriptor",
    "public_key_der",
    "validate_raw_image",
    "verify_package",
]
