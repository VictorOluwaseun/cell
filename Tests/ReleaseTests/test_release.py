import hashlib
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("cell_release", Path(__file__).resolve().parents[2] / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = release
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_tag_becomes_valid_apple_bundle_version(self):
        value = release.metadata("v1.2.3-beta.1", "42", "developer-id")
        self.assertEqual(value["bundle_version"], "1.2.3")
        self.assertEqual(value["version"], "1.2.3-beta.1")
        self.assertEqual(value["stem"], "Cell-1.2.3-beta.1-universal")
        self.assertTrue(value["prerelease"])

    def test_unsigned_build_is_always_marked_as_prerelease(self):
        unsigned = release.metadata("v1.2.3", "1", "adhoc")
        self.assertTrue(unsigned["prerelease"])
        self.assertTrue(unsigned["stem"].endswith("-unsigned"))
        self.assertFalse(release.metadata("1.2.3", "1", "developer-id")["prerelease"])

    def test_rejects_unsafe_or_ambiguous_versions(self):
        for value in ("", "v1.2", "v01.2.3", "v1.2.3-01", "v1.2.3-rc.01", "v1.2.3+build", "../1.2.3", "1.2.3\nx=y", "1.2.3/rc", "1.2.3; echo bad", "v１.2.3"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.Version.parse(value)

    def test_build_numbers_and_signing_modes_are_validated(self):
        for build in ("0", "-1", "1\nx=y", "01", "1234567890"):
            with self.subTest(build=build), self.assertRaises(ValueError):
                release.metadata("v1.2.3", build, "adhoc")
        with self.assertRaises(ValueError):
            release.metadata("v1.2.3", "1", "unknown")

    def test_signing_configuration_fails_closed_without_notarization(self):
        with patch.dict(os.environ, {"CELL_SIGNING_IDENTITY": "Developer ID Application: Example", "CELL_INSTALLER_IDENTITY": "Developer ID Installer: Example"}, clear=True):
            with self.assertRaises(ValueError):
                release.signing_environment("developer-id")
        with patch.dict(os.environ, {"CELL_SIGNING_IDENTITY": "Developer ID Application: Example"}, clear=True):
            self.assertEqual(release.signing_environment("adhoc")["CELL_SIGNING_IDENTITY"], "-")

    def test_checksum_manifest_is_deterministic_and_excludes_itself(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "b.pkg").write_bytes(b"package")
            (folder / "a.zip").write_bytes(b"archive")
            (folder / "SHA256SUMS").write_text("stale")
            release.write_checksums(folder)
            expected = f'{hashlib.sha256(b"archive").hexdigest()}  a.zip\n{hashlib.sha256(b"package").hexdigest()}  b.pkg\n'
            self.assertEqual((folder / "SHA256SUMS").read_text(), expected)
            release.write_checksums(folder)
            self.assertEqual((folder / "SHA256SUMS").read_text(), expected)

    def test_packaging_never_overwrites_an_existing_release(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(release.sys, "platform", "darwin"):
            folder = Path(directory)
            (folder / "keep.pkg").write_bytes(b"keep")
            with self.assertRaises(ValueError):
                release.build(release.metadata("v1.2.3", "1", "adhoc"), folder)
            self.assertEqual((folder / "keep.pkg").read_bytes(), b"keep")


if __name__ == "__main__":
    unittest.main()
