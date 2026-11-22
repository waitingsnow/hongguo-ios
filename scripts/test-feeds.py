#!/usr/bin/env python3
"""Offline feed/IPA validation tests. Synthetic Mach-O fixtures never bypass CLI validation."""
from __future__ import annotations

import base64
import importlib.util
import json
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("generate_feeds", Path(__file__).with_name("generate-feeds.py"))
feeds = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feeds)
release_spec = importlib.util.spec_from_file_location("release_common", Path(__file__).with_name("release-common.py"))
release = importlib.util.module_from_spec(release_spec)
release_spec.loader.exec_module(release)
verify_path = Path(__file__).with_name("verify-ipa.py")
OPENHONGGUO_WORKSPACE = b"/Users/runner/work/openhongguo/openhongguo"
OPENHONGGUO_MODULE_RECORDS = (
    b"\ndep\tgithub.com/beilunyang/openhongguo\tv0.0.0\n=>\t"
    + OPENHONGGUO_WORKSPACE + b"\t(devel)\t\n",
    b"\ndep\tgithub.com/beilunyang/openhongguo/bindings/mobile/core\tv0.0.0-00010101000000-000000000000\n=>\t"
    + OPENHONGGUO_WORKSPACE + b"/bindings/mobile/core\t(devel)\t\n",
)


class FeedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hongguo-feed-tests-")
        self.root = Path(self.temporary.name)
        self.config = {"version": "0.1.1", "build": 2, "repository": "waitingsnow/hongguo-ios", "minimumOSVersion": "17.0",
                       "minimumBuildSDK": "27.1", "releaseNotes": ["合成发布测试"]}
        self.config_path = self.root / "Release.json"
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        self.output = self.root / "distribution"
        self.output.mkdir()
        self.output.joinpath("icon.png").write_bytes(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="))
        self.ipa = self.root / "Hongguo-iOS-0.1.1-unsigned.ipa"

    def tearDown(self):
        self.temporary.cleanup()

    def package(self, changes=None, *, signature=False, profile=False, signature_directory=False, platform=2, deployment=17 << 16,
                corrupt_path=False, extra=(), binary_data=b""):
        info = {"CFBundleIdentifier": feeds.BUNDLE_ID, "CFBundleShortVersionString": "0.1.1", "CFBundleVersion": "2",
                "MinimumOSVersion": "17.0", "CFBundleSupportedPlatforms": ["iPhoneOS"], "CFBundleExecutable": "Hongguo",
                "DTPlatformVersion": "27.2"}
        info.update(changes or {})
        command = struct.pack("<6I", 0x32, 24, platform, deployment, 0, 0)
        if signature:
            command += struct.pack("<4I", 0x1D, 16, 0, 0)
        binary = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 2 if signature else 1, len(command), 0, 0) + command
        with zipfile.ZipFile(self.ipa, "w") as archive:
            prefix = "Payload/Hongguo.app/"
            archive.writestr(prefix + "Info.plist", plistlib.dumps(info))
            archive.writestr(prefix + "Hongguo", binary + binary_data)
            for resource in ("PureSign.js", "BufferRuntime.js", "PlayerSignV5.js", "Assets.car"):
                archive.writestr(prefix + resource, b"synthetic test resource")
            if profile:
                archive.writestr(prefix + "embedded.mobileprovision", b"synthetic")
            if signature_directory:
                archive.writestr(prefix + "_CodeSignature/CodeResources", b"synthetic")
            if corrupt_path:
                archive.writestr("../../escape", b"synthetic")
            for name, contents in extra:
                archive.writestr(name, contents)

    def generate(self, **options):
        return feeds.generate(self.config_path, self.ipa, self.output, tag="v0.1.1", published_at="2026-10-28T12:00:00Z", use_codesign=False, **options)

    def verify_new_build(self):
        return subprocess.run([sys.executable, verify_path, self.ipa, "--config", self.config_path],
                              capture_output=True, text=True)

    def test_consistent_actual_metadata_and_urls(self):
        self.package()
        report = self.generate()
        update = json.loads((self.output / "update.json").read_text())
        self.assertEqual(update["sha256"], feeds.file_sha256(self.ipa))
        self.assertEqual(update["size"], self.ipa.stat().st_size)
        self.assertEqual(update["build"], 2)
        self.assertTrue(report["unsigned"])
        direct = "https://github.com/waitingsnow/hongguo-ios/releases/download/v0.1.1/Hongguo-iOS-0.1.1-unsigned.ipa"
        for filename, prefix in [("source.json", ""), ("source-cn.json", "https://gh-proxy.com/"), ("source-cn-backup.json", "https://ghfast.top/")]:
            source = json.loads((self.output / filename).read_text())
            app = source["apps"][0]
            self.assertEqual(app["downloadURL"], prefix + direct)
            self.assertEqual(source["sourceURL"], prefix + "https://raw.githubusercontent.com/waitingsnow/hongguo-ios/main/distribution/" + filename)
            self.assertEqual(app["iconURL"], prefix + "https://raw.githubusercontent.com/waitingsnow/hongguo-ios/v0.1.1/distribution/icon.png")
            for key in ("version", "build", "minimumOSVersion", "sha256"):
                self.assertEqual(app[key], update[key])
            self.assertEqual(int(app["size"]), update["size"])
            self.assertEqual(app["versionDate"], update["publishedAt"])
        self.generate(check=True)

    def test_metadata_drift_is_rejected(self):
        for changes in [{"CFBundleShortVersionString": "0.1.0"}, {"CFBundleVersion": "1"}, {"MinimumOSVersion": "16.0"},
                        {"CFBundleIdentifier": "invalid.bundle"}, {"CFBundleSupportedPlatforms": ["iPhoneSimulator"]}]:
            with self.subTest(changes=changes):
                self.package(changes)
                with self.assertRaises(feeds.ValidationError):
                    self.generate()
                self.assertFalse((self.output / "update.json").exists())

    def test_signed_and_provisioned_packages_are_rejected(self):
        for options in [{"signature": True}, {"profile": True}, {"signature_directory": True}]:
            with self.subTest(options=options):
                self.package(**options)
                with self.assertRaises(feeds.ValidationError):
                    self.generate()

    def test_private_ipa_resources_are_rejected_before_extraction(self):
        for name in ("alternate.MobileProvision", "Developer.PROVISIONPROFILE", "Certificate.CER", "keys/key.P12",
                     "AppleAuth.P8", "certificate.pem", "codesign.xcent", "debug.entitlements",
                     "nested/_codesignature/CodeResources", ".env.local", "Configuration/Local.xcconfig"):
            with self.subTest(name=name):
                self.package(extra=[("Payload/Hongguo.app/" + name, b"fixture only")])
                with self.assertRaisesRegex(feeds.ValidationError, "Private paths or signing material"):
                    self.generate()

    def test_new_build_rejects_private_home_paths_without_echoing_them(self):
        for path, kind in [(b"/Users/fixture-person/Development/File.swift", "macOS home"),
                           (b"/System/Volumes/Data/Users/fixture-person", "macOS home"),
                           (b"/private/var/root/Sources", "macOS root home"),
                           (b"/home/fixture-person/work.c", "Linux home"),
                           (b"/root/source", "Linux root home"),
                           (rb"C:\Users\fixture-person\source", "Windows home")]:
            with self.subTest(kind=kind):
                self.package(binary_data=b"\0" * (65536 - 60) + path + b"\0")
                result = subprocess.run([sys.executable, "-O", verify_path, self.ipa, "--config", self.config_path],
                                        capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"Private absolute home path detected ({kind})".encode(), result.stderr)
                self.assertNotIn(path, result.stderr + result.stdout)
                self.generate()
                self.generate(check=True)

    def test_new_build_resource_scan_accepts_public_paths_and_rejects_renamed_material(self):
        self.package(binary_data=b"\0/Users/Shared/work\0docs/Users/example\0")
        self.assertEqual(self.verify_new_build().returncode, 0)
        for contents, message in [(b"-----BEGIN PRIVATE KEY-----\nZml4dHVyZQ==\n", "PEM signing material"),
                                  (bytes.fromhex("cffaedfe"), "Unexpected embedded Mach-O")]:
            self.package(extra=[("Payload/Hongguo.app/resources.bin", contents)])
            result = self.verify_new_build()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)

    def test_openhongguo_module_records_are_accepted_across_scan_boundaries(self):
        for record in OPENHONGGUO_MODULE_RECORDS:
            path_offset = record.index(OPENHONGGUO_WORKSPACE)
            for boundary in (1, path_offset, path_offset + 8, len(record) - 1):
                with self.subTest(record=record, boundary=boundary):
                    self.package(binary_data=b"\0" * (65536 - 56 - boundary) + record)
                    result = self.verify_new_build()
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_openhongguo_module_exception_is_limited_to_complete_executable_records(self):
        record, mobile_record = OPENHONGGUO_MODULE_RECORDS
        private_path = b"/Users/fixture-person/source.swift"
        for content in (
            OPENHONGGUO_WORKSPACE,
            record[:-1],
            record.replace(b"\ndep\t", b"\nother dep\t"),
            record.replace(b"github.com/beilunyang/openhongguo", b"github.com/another/openhongguo"),
            record.replace(b"v0.0.0", b"v0.4.0"),
            mobile_record.replace(b"00010101000000", b"20261122000000"),
            record.replace(b"(devel)\t\n", b"(devel)\tmodified\n"),
            record.replace(OPENHONGGUO_WORKSPACE, OPENHONGGUO_WORKSPACE + b"/go.mod"),
            record + OPENHONGGUO_WORKSPACE + b"\0",
            record + private_path + b"\0",
            private_path + b"\0" + record,
        ):
            with self.subTest(content=content):
                self.package(binary_data=b"\0" + content)
                result = self.verify_new_build()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Private absolute home path detected (macOS home)", result.stderr)
                self.assertNotIn(private_path.decode(), result.stdout + result.stderr)
        self.package(binary_data=record, extra=[("Payload/Hongguo.app/Resources/Hongguo", record)])
        result = self.verify_new_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Private absolute home path detected (macOS home)", result.stderr)

        self.package(binary_data=mobile_record + b"\n-----BEGIN PRIVATE KEY-----\nZml4dHVyZQ==\n")
        result = self.verify_new_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PEM signing material", result.stderr)

    def test_new_build_rejects_uid_gid_extra_fields_in_both_zip_headers(self):
        entry = zipfile.ZipInfo("Payload/Hongguo.app/metadata.txt")
        entry.extra = struct.pack("<HH", 0x7875, 7) + b"\x01\x02\xe8\x03\x02\xe8\x03"
        self.package(extra=[(entry, b"fixture")])
        original = self.ipa.read_bytes()
        for local_only, location in [(False, "central-directory"), (True, "local-header")]:
            with self.subTest(location=location):
                if local_only:
                    with zipfile.ZipFile(self.ipa) as archive:
                        central = archive.start_dir
                        for item in archive.infolist()[:-1]:
                            central += 46 + len(item.filename) + len(item.extra) + len(item.comment)
                    data = bytearray(original)
                    start_extra = central + 46 + len(entry.filename)
                    del data[start_extra:start_extra + len(entry.extra)]
                    struct.pack_into("<H", data, central + 30, 0)
                    end_record = len(data) - 22
                    struct.pack_into("<I", data, end_record + 12, end_record - archive.start_dir)
                    self.ipa.write_bytes(data)
                result = subprocess.run([sys.executable, verify_path, self.ipa, "--config", self.config_path],
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"ZIP {location} extra fields", result.stderr)
                self.generate()
                self.generate(check=True)

    def test_bad_archive_traversal_and_binary_target_are_rejected(self):
        for options in [{"corrupt_path": True}, {"platform": 7}, {"deployment": 16 << 16}]:
            with self.subTest(options=options):
                self.package(**options)
                with self.assertRaises(feeds.ValidationError):
                    self.generate()
        self.ipa.write_bytes(b"not a zip")
        with self.assertRaises(feeds.ValidationError):
            self.generate()

    def test_source_tampering_fails_check_without_changing_files(self):
        self.package(); self.generate()
        path = self.output / "source-cn.json"
        tampered = json.loads(path.read_text())
        tampered["apps"][0]["sha256"] = "0" * 64
        path.write_text(json.dumps(tampered))
        original = path.read_bytes()
        with self.assertRaises(feeds.ValidationError):
            self.generate(check=True)
        self.assertEqual(path.read_bytes(), original)

    def test_tag_config_filename_and_timestamp_are_validated(self):
        self.package()
        with self.assertRaises(feeds.ValidationError):
            feeds.read_config(self.config_path, "v0.1.2")
        with self.assertRaises(feeds.ValidationError):
            feeds.timestamp("2026-10-28T12:00:00")
        renamed = self.ipa.with_name("wrong.ipa")
        self.ipa.rename(renamed)
        with self.assertRaises(feeds.ValidationError):
            feeds.validate_ipa(renamed, self.config, use_codesign=False)
        self.assertEqual(feeds.timestamp("2026-10-28T08:00:00-04:00"), "2026-10-28T12:00:00Z")

    def test_failed_ipa_validation_does_not_overwrite_published_metadata(self):
        self.package(); self.generate()
        before = {name: (self.output / name).read_bytes() for name in feeds.GENERATED}
        self.package({"CFBundleVersion": "99"})
        with self.assertRaises(feeds.ValidationError):
            self.generate()
        self.assertEqual(before, {name: (self.output / name).read_bytes() for name in feeds.GENERATED})

    def test_rest_only_a_real_404_means_release_absent(self):
        def response(status, body, code):
            return mock.Mock(stdout=f"HTTP/2.0 {status} Test\r\nContent-Type: application/json\r\n\r\n{body}", returncode=code)
        with mock.patch.object(release.subprocess, "run", return_value=response(404, '{"message":"Not Found"}', 1)):
            self.assertIsNone(release.api_json("repos/example/test/releases/latest", missing_ok=True))
        for reply in [response(401, '{}', 1), response(500, '{}', 1), mock.Mock(stdout="", returncode=1)]:
            with mock.patch.object(release.subprocess, "run", return_value=reply):
                with self.assertRaises(RuntimeError):
                    release.api_json("repos/example/test/releases/latest", missing_ok=True)
        with mock.patch.object(release.subprocess, "run", return_value=response(200, '{"tag_name":"v0.1.1"}', 0)):
            self.assertEqual(release.latest("example/test")["tag_name"], "v0.1.1")

    def test_version_comparison_is_numeric(self):
        self.assertGreater(release.version("v0.1.10"), release.version("v0.1.9"))
        self.assertGreater(release.version("v1.0.0"), release.version("v0.99.99"))
        for bad in ["v0.1", "v0.1.1-beta", "../v0.1.1", "v0.1.1\n"]:
            with self.assertRaises(ValueError):
                release.version(bad)

    def test_stable_sync_rejects_draft_and_prerelease_assets(self):
        for draft, prerelease in [(True, False), (False, True), (True, True)]:
            with mock.patch.object(release, "api_json", return_value={"draft": draft, "prerelease": prerelease, "tag_name": "v0.1.1"}):
                with self.assertRaises(RuntimeError):
                    release.published_release("example/test", "v0.1.1")
        with mock.patch.object(release, "api_json", return_value={"draft": False, "prerelease": False, "tag_name": "v0.1.1"}):
            self.assertEqual(release.published_release("example/test", "v0.1.1")["tag_name"], "v0.1.1")


if __name__ == "__main__":
    unittest.main(verbosity=2)
