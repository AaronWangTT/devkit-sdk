from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path

from az3166_ota.package import load_public_key, verify_package


class GoldenVectorTests(unittest.TestCase):
    def test_core_compatible_fixed_package(self) -> None:
        data = Path(__file__).parent / "data"
        manifest = json.loads((data / "golden-vector.json").read_text(encoding="utf-8"))
        package = (data / "golden-package.azpkg").read_bytes()
        public_key, public_der = load_public_key(data / "golden-public.der")

        self.assertEqual(hashlib.sha256(package).hexdigest(), manifest["packageSha256"])
        self.assertEqual(hashlib.sha256(public_der).hexdigest(), manifest["keyId"])
        verified = verify_package(package, public_key, public_der)
        self.assertEqual(verified.descriptor.product_id, manifest["product"])
        self.assertEqual(verified.descriptor.board_id, manifest["board"])
        self.assertEqual(verified.descriptor.firmware_version, manifest["version"])
        self.assertEqual(verified.descriptor.source_commit, manifest["source"])
        self.assertEqual(verified.payload_sha256.hex(), manifest["payloadSha256"])
        self.assertEqual(verified.payload_length, manifest["payloadLength"])


if __name__ == "__main__":
    unittest.main()
