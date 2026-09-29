from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import sys
from pathlib import Path

from .keys import generate_key_pair
from .package import (
    PackageError,
    build_package,
    load_private_key,
    load_public_key,
    validate_raw_image,
    verify_package,
)


def _integer(value: str) -> int:
    try:
        parsed = int(value, 0)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer or 0x-prefixed integer") from error
    if parsed < 0 or parsed > 0xFFFFFFFF:
        raise argparse.ArgumentTypeError("must be an unsigned 32-bit integer")
    return parsed


def _expected(args: argparse.Namespace) -> dict[str, object]:
    return {
        "expected_product": args.product,
        "expected_board": args.board,
        "expected_version": args.version,
        "expected_source": args.source,
        "expected_address": args.address,
        "expected_capacity": args.capacity,
    }


def _metadata(descriptor, *, payload_length: int | None = None, digest: bytes | None = None):
    result = {
        "product": descriptor.product_id,
        "board": descriptor.board_id,
        "version": descriptor.firmware_version,
        "source": descriptor.source_commit,
        "applicationAddress": descriptor.application_address,
        "applicationCapacity": descriptor.application_capacity,
        "keyId": descriptor.key_id.hex(),
    }
    if payload_length is not None:
        result["payloadLength"] = payload_length
    if digest is not None:
        result["sha256"] = digest.hex()
    return result


def _atomic_output(path: Path, data: bytes) -> None:
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(8)}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _paths_alias(first: Path, second: Path) -> bool:
    first_resolved = first.parent.resolve(strict=True) / first.name
    second_resolved = second.parent.resolve(strict=True) / second.name
    if os.path.normcase(str(first_resolved)) == os.path.normcase(
        str(second_resolved)
    ):
        return True
    return first.exists() and second.exists() and os.path.samefile(first, second)


def _command_generate_key(args: argparse.Namespace) -> None:
    public_der, key_id = generate_key_pair(
        args.private_key,
        args.public_key,
        overwrite=args.force,
        create_parents=args.create_parents,
    )
    print(
        json.dumps(
            {
                "keyId": key_id,
                "publicKeySha256": hashlib.sha256(public_der).hexdigest(),
                "privateKeyPath": str(args.private_key),
                "publicKeyPath": str(args.public_key),
            },
            separators=(",", ":"),
        )
    )


def _command_validate(args: argparse.Namespace) -> None:
    _, public_der = load_public_key(args.public_key)
    image = args.image.read_bytes()
    descriptor = validate_raw_image(
        image,
        key_id=hashlib.sha256(public_der).digest(),
        **_expected(args),
    )
    print(json.dumps(_metadata(descriptor), separators=(",", ":")))


def _command_build(args: argparse.Namespace) -> None:
    if not args.output.parent.is_dir():
        raise PackageError(f"output parent directory does not exist: {args.output.parent}")
    if _paths_alias(args.output, args.private_key):
        raise PackageError("package output must not alias the private key")
    private_key = load_private_key(args.private_key)
    package = build_package(
        args.image.read_bytes(),
        private_key,
        **_expected(args),
    )
    _atomic_output(args.output, package)
    print(f"wrote {len(package)} bytes to {args.output}")


def _command_verify(args: argparse.Namespace) -> None:
    public_key, public_der = load_public_key(args.public_key)
    verified = verify_package(
        args.package.read_bytes(),
        public_key,
        public_der,
        **_expected(args),
    )
    print(
        json.dumps(
            _metadata(
                verified.descriptor,
                payload_length=verified.payload_length,
                digest=verified.payload_sha256,
            ),
            separators=(",", ":"),
        )
    )


def _add_expected(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--product", help="require this descriptor product ID")
    parser.add_argument("--board", help="require this descriptor board ID")
    parser.add_argument("--version", help="require this canonical firmware version")
    parser.add_argument("--source", help="require this 40-character source commit")
    parser.add_argument("--address", type=_integer, help="require this application address")
    parser.add_argument("--capacity", type=_integer, help="require this application capacity")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Build and verify generic AZ3166 signed OTA packages"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    generate = subparsers.add_parser("generate-key", help="generate a P-256 signing key pair")
    generate.add_argument("--private-key", type=Path, required=True)
    generate.add_argument("--public-key", type=Path, required=True)
    generate.add_argument("--force", action="store_true", help="replace existing key files")
    generate.add_argument(
        "--create-parents",
        action="store_true",
        help="create missing parent directories",
    )
    generate.set_defaults(handler=_command_generate_key)

    validate = subparsers.add_parser("validate-image", help="validate a raw AZ3166 image")
    validate.add_argument("--image", type=Path, required=True)
    validate.add_argument("--public-key", type=Path, required=True)
    _add_expected(validate)
    validate.set_defaults(handler=_command_validate)

    build = subparsers.add_parser("build", help="validate and sign an OTA package")
    build.add_argument("--image", type=Path, required=True)
    build.add_argument("--output", type=Path, required=True)
    build.add_argument("--private-key", type=Path, required=True)
    _add_expected(build)
    build.set_defaults(handler=_command_build)

    verify = subparsers.add_parser("verify", help="verify an OTA package")
    verify.add_argument("--package", type=Path, required=True)
    verify.add_argument("--public-key", type=Path, required=True)
    _add_expected(verify)
    verify.set_defaults(handler=_command_verify)
    return parser


def main(argv: list[str] | None = None) -> int:
    try:
        args = _parser().parse_args(argv)
        args.handler(args)
        return 0
    except (OSError, PackageError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
