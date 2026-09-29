from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cryptography.hazmat.primitives import serialization

import az3166_ota.keys as key_module
from az3166_ota.cli import main
from az3166_ota.keys import generate_key_pair
from az3166_ota.package import PackageError, load_private_key, load_public_key
from test_package import BOARD, PRODUCT, VERSION, make_image


class KeyAndCliTests(unittest.TestCase):
    def test_generate_key_pair_writes_canonical_formats(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private_path = root / "private.pem"
            public_path = root / "public.der"
            public_der, key_id = generate_key_pair(private_path, public_path)

            private_key = load_private_key(private_path)
            public_key, loaded_der = load_public_key(public_path)
            self.assertEqual(loaded_der, public_der)
            self.assertEqual(key_id, hashlib.sha256(public_der).hexdigest())
            self.assertEqual(
                private_key.public_key().public_numbers(), public_key.public_numbers()
            )
            self.assertTrue(
                private_path.read_bytes().startswith(b"-----BEGIN PRIVATE KEY-----\n")
            )
            self.assertEqual(
                private_path.read_bytes(),
                private_key.private_bytes(
                    serialization.Encoding.PEM,
                    serialization.PrivateFormat.PKCS8,
                    serialization.NoEncryption(),
                ),
            )

    def test_refuses_overwrite_without_force(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private_path = root / "private.pem"
            public_path = root / "public.der"
            private_path.write_text("sentinel", encoding="ascii")
            with self.assertRaisesRegex(PackageError, "overwrite"):
                generate_key_pair(private_path, public_path)
            self.assertEqual(private_path.read_text(encoding="ascii"), "sentinel")
            self.assertFalse(public_path.exists())

    def test_force_replaces_both_key_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private_path = root / "private.pem"
            public_path = root / "public.der"
            private_path.write_text("old private", encoding="ascii")
            public_path.write_text("old public", encoding="ascii")
            generate_key_pair(private_path, public_path, overwrite=True)
            load_private_key(private_path)
            load_public_key(public_path)

    def test_force_preserves_existing_pair_when_publication_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private_path = root / "private.pem"
            public_path = root / "public.der"
            private_path.write_bytes(b"old private")
            public_path.write_bytes(b"old public")
            original_publish = key_module._publish_staged
            publication_count = 0

            def fail_second_publication(temporary, path, overwrite):
                nonlocal publication_count
                publication_count += 1
                if publication_count == 2:
                    raise OSError("injected public-key publication failure")
                original_publish(temporary, path, overwrite)

            with patch.object(
                key_module,
                "_publish_staged",
                side_effect=fail_second_publication,
            ):
                with self.assertRaisesRegex(OSError, "injected"):
                    generate_key_pair(private_path, public_path, overwrite=True)

            self.assertEqual(private_path.read_bytes(), b"old private")
            self.assertEqual(public_path.read_bytes(), b"old public")
            self.assertEqual(
                {path.name for path in root.iterdir()},
                {"private.pem", "public.der"},
            )

    def test_rollback_failure_retains_exact_recovery_backup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private_path = root / "private.pem"
            public_path = root / "public.der"
            private_path.write_bytes(b"old private")
            public_path.write_bytes(b"old public")
            original_publish = key_module._publish_staged
            original_restore = key_module._restore_backup
            publication_count = 0

            def fail_second_publication(temporary, path, overwrite):
                nonlocal publication_count
                publication_count += 1
                if publication_count == 2:
                    raise OSError("injected public-key publication failure")
                original_publish(temporary, path, overwrite)

            def fail_private_restore(backup, path):
                if path == private_path:
                    raise OSError("injected private-key restoration failure")
                original_restore(backup, path)

            with patch.object(
                key_module,
                "_publish_staged",
                side_effect=fail_second_publication,
            ), patch.object(
                key_module,
                "_restore_backup",
                side_effect=fail_private_restore,
            ):
                with self.assertRaisesRegex(
                    PackageError, "recovery copies retained"
                ) as raised:
                    generate_key_pair(private_path, public_path, overwrite=True)

            backups = list(root.glob(".private.pem.*.backup"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_bytes(), b"old private")
            self.assertIn(str(private_path), str(raised.exception))
            self.assertIn(str(backups[0]), str(raised.exception))
            self.assertNotIn("old private", str(raised.exception))
            self.assertEqual(public_path.read_bytes(), b"old public")
            self.assertEqual(list(root.glob(".public.der.*.backup")), [])

    def test_non_overwrite_removes_new_pair_when_publication_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private_path = root / "private.pem"
            public_path = root / "public.der"
            original_publish = key_module._publish_staged
            publication_count = 0

            def fail_second_publication(temporary, path, overwrite):
                nonlocal publication_count
                publication_count += 1
                if publication_count == 2:
                    raise OSError("injected public-key publication failure")
                original_publish(temporary, path, overwrite)

            with patch.object(
                key_module,
                "_publish_staged",
                side_effect=fail_second_publication,
            ):
                with self.assertRaisesRegex(OSError, "injected"):
                    generate_key_pair(private_path, public_path)

            self.assertFalse(private_path.exists())
            self.assertFalse(public_path.exists())
            self.assertEqual(list(root.iterdir()), [])

    def test_parent_creation_is_explicit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "new" / "keys"
            private_path = root / "private.pem"
            public_path = root / "public.der"
            with self.assertRaisesRegex(PackageError, "create-parents"):
                generate_key_pair(private_path, public_path)
            self.assertFalse(root.exists())
            generate_key_pair(
                private_path, public_path, create_parents=True
            )
            self.assertTrue(private_path.exists())
            self.assertTrue(public_path.exists())

    def test_rejects_same_output_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "key"
            with self.assertRaisesRegex(PackageError, "different"):
                generate_key_pair(path, path)

    def test_rejects_parent_symlink_aliases(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            actual_parent = root / "actual"
            alias_parent = root / "alias"
            actual_parent.mkdir()
            try:
                alias_parent.symlink_to(actual_parent, target_is_directory=True)
            except (NotImplementedError, OSError) as error:
                self.skipTest(f"directory symlinks unavailable: {error}")

            private_path = actual_parent / "same-key"
            public_path = alias_parent / "same-key"
            with self.assertRaisesRegex(PackageError, "resolve to different"):
                generate_key_pair(private_path, public_path)
            self.assertFalse(private_path.exists())

    def test_rejects_existing_hard_link_aliases(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private_path = root / "private.pem"
            public_path = root / "public.der"
            private_path.write_bytes(b"same inode")
            public_path.hardlink_to(private_path)
            with self.assertRaisesRegex(PackageError, "resolve to different"):
                generate_key_pair(private_path, public_path, overwrite=True)
            self.assertEqual(private_path.read_bytes(), b"same inode")
            self.assertTrue(os.path.samefile(private_path, public_path))

    def test_generate_key_cli_prints_only_public_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private_path = root / "private.pem"
            public_path = root / "public.der"
            stdout = io.StringIO()
            stderr = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                result = main(
                    [
                        "generate-key",
                        "--private-key",
                        str(private_path),
                        "--public-key",
                        str(public_path),
                    ]
                )
            self.assertEqual(result, 0)
            payload = json.loads(stdout.getvalue())
            self.assertEqual(payload["privateKeyPath"], str(private_path))
            self.assertEqual(payload["publicKeyPath"], str(public_path))
            self.assertEqual(payload["keyId"], payload["publicKeySha256"])
            self.assertNotIn("BEGIN PRIVATE KEY", stdout.getvalue())
            self.assertNotIn(private_path.read_text(encoding="ascii"), stdout.getvalue())
            self.assertEqual(stderr.getvalue(), "")

    def test_cli_errors_do_not_emit_private_material(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "private.pem"
            path.write_text("secret sentinel", encoding="ascii")
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                result = main(
                    [
                        "generate-key",
                        "--private-key",
                        str(path),
                        "--public-key",
                        str(Path(directory) / "public.der"),
                    ]
                )
            self.assertEqual(result, 2)
            self.assertNotIn("secret sentinel", stderr.getvalue())

    def test_cli_validates_builds_and_verifies_package(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private_path = root / "private.pem"
            public_path = root / "public.der"
            image_path = root / "application.bin"
            package_path = root / "application.azpkg"
            public_der, _ = generate_key_pair(private_path, public_path)
            image_path.write_bytes(make_image(public_der))

            common_policy = [
                "--product",
                PRODUCT,
                "--board",
                BOARD,
                "--version",
                VERSION,
            ]
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(
                    main(
                        [
                            "validate-image",
                            "--image",
                            str(image_path),
                            "--public-key",
                            str(public_path),
                            *common_policy,
                        ]
                    ),
                    0,
                )
                self.assertEqual(
                    main(
                        [
                            "build",
                            "--image",
                            str(image_path),
                            "--private-key",
                            str(private_path),
                            "--output",
                            str(package_path),
                            *common_policy,
                        ]
                    ),
                    0,
                )
                self.assertEqual(
                    main(
                        [
                            "verify",
                            "--package",
                            str(package_path),
                            "--public-key",
                            str(public_path),
                            *common_policy,
                        ]
                    ),
                    0,
                )
            self.assertTrue(package_path.exists())


if __name__ == "__main__":
    unittest.main()
