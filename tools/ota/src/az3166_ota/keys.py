from __future__ import annotations

import errno
import hashlib
import os
import secrets
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from .package import PackageError


def _stage_file(path: Path, data: bytes, mode: int, kind: str) -> Path:
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(8)}.{kind}")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    return temporary


def _publish_staged(temporary: Path, path: Path, overwrite: bool) -> None:
    if overwrite:
        os.replace(temporary, path)
        return
    try:
        os.link(temporary, path)
    except OSError as error:
        if error.errno in (errno.EEXIST, errno.EACCES) and path.exists():
            raise FileExistsError(path) from error
        raise


def _backup_existing(path: Path) -> Path | None:
    if not path.exists():
        return None
    backup = path.with_name(f".{path.name}.{secrets.token_hex(8)}.backup")
    os.link(path, backup)
    return backup


def _restore_backup(backup: Path, path: Path) -> None:
    if path.exists() and os.path.samefile(backup, path):
        backup.unlink()
        return
    os.replace(backup, path)


def _rollback_outputs(
    paths: tuple[Path, Path],
    staged: dict[Path, Path],
    backups: dict[Path, Path],
    attempted: set[Path],
    published: set[Path],
    overwrite: bool,
) -> None:
    restore_errors: list[tuple[Path, Path, OSError]] = []
    cleanup_errors: list[tuple[Path, OSError]] = []
    for path in reversed(paths):
        backup = backups.get(path)
        try:
            if backup is not None:
                _restore_backup(backup, path)
            elif path in attempted and path.exists():
                temporary = staged[path]
                if overwrite or path in published or (
                    temporary.exists() and os.path.samefile(temporary, path)
                ):
                    path.unlink()
        except OSError as error:
            if backup is not None:
                restore_errors.append((path, backup, error))
            else:
                cleanup_errors.append((path, error))
    if restore_errors:
        recovery = "; ".join(
            f"restore {path.absolute()} from {backup.absolute()}"
            for path, backup, _ in restore_errors
        )
        raise PackageError(
            f"key-pair rollback incomplete; recovery copies retained: {recovery}"
        ) from restore_errors[0][2]
    if cleanup_errors:
        paths_text = ", ".join(str(path) for path, _ in cleanup_errors)
        raise PackageError(
            f"key-pair rollback incomplete; remove partial outputs: {paths_text}"
        ) from cleanup_errors[0][1]


def _publish_pair(
    private_path: Path,
    private_pem: bytes,
    public_path: Path,
    public_der: bytes,
    overwrite: bool,
) -> None:
    paths = (private_path, public_path)
    staged: dict[Path, Path] = {}
    backups: dict[Path, Path] = {}
    attempted: set[Path] = set()
    published: set[Path] = set()
    committed = False
    try:
        if overwrite:
            for path in paths:
                backup = _backup_existing(path)
                if backup is not None:
                    backups[path] = backup
        staged[private_path] = _stage_file(private_path, private_pem, 0o600, "tmp")
        staged[public_path] = _stage_file(public_path, public_der, 0o644, "tmp")
        for path in paths:
            attempted.add(path)
            _publish_staged(staged[path], path, overwrite)
            published.add(path)
        committed = True
    except Exception:
        _rollback_outputs(paths, staged, backups, attempted, published, overwrite)
        raise
    finally:
        for temporary in staged.values():
            temporary.unlink(missing_ok=True)
        if committed:
            for backup in backups.values():
                backup.unlink(missing_ok=True)


def _resolved_destination(path: Path) -> Path:
    parent = path.parent.resolve(strict=True)
    return (parent / path.name).resolve(strict=False)


def _destinations_match(private_path: Path, public_path: Path) -> bool:
    private_resolved = _resolved_destination(private_path)
    public_resolved = _resolved_destination(public_path)
    if os.path.normcase(str(private_resolved)) == os.path.normcase(
        str(public_resolved)
    ):
        return True
    if private_path.exists() and public_path.exists():
        return os.path.samefile(private_path, public_path)
    return False


def generate_key_pair(
    private_path: Path,
    public_path: Path,
    *,
    overwrite: bool = False,
    create_parents: bool = False,
) -> tuple[bytes, str]:
    """Generate P-256 PKCS#8 PEM and RFC 5480 DER files atomically."""
    private_identity = os.path.normcase(os.path.abspath(private_path))
    public_identity = os.path.normcase(os.path.abspath(public_path))
    if private_identity == public_identity:
        raise PackageError("private-key and public-key paths must be different")
    paths = (private_path, public_path)
    for parent in {path.parent for path in paths}:
        if create_parents:
            parent.mkdir(parents=True, exist_ok=True)
        elif not parent.is_dir():
            raise PackageError(
                f"parent directory does not exist: {parent}; use --create-parents"
            )
    if any(path.is_symlink() for path in paths):
        raise PackageError("private-key and public-key destinations must not be symlinks")
    if _destinations_match(private_path, public_path):
        raise PackageError("private-key and public-key paths must resolve to different files")
    if not overwrite:
        existing = [str(path) for path in paths if path.exists()]
        if existing:
            raise PackageError(f"refusing to overwrite existing path: {existing[0]}")

    key = ec.generate_private_key(ec.SECP256R1())
    private_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    public_der = key.public_key().public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    _publish_pair(private_path, private_pem, public_path, public_der, overwrite)
    return public_der, hashlib.sha256(public_der).hexdigest()
