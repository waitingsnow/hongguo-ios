#!/usr/bin/env python3
"""Offline source and release preparation tests using only temporary Git repositories."""
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = "Hongguo-iOS-1.2.3-source.zip"
IPA = "Hongguo-iOS-1.2.3-unsigned.ipa"


class PackagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="hongguo-package-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Packaging Test")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "core.hooksPath", "/dev/null")
        (self.root / "scripts").mkdir()
        for name in ("package-source.py", "package_rules.py", "release.sh"):
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
        shutil.copy2(ROOT / ".gitignore", self.root / ".gitignore")
        self.write("Configuration/Release.json", json.dumps(
            {"version": "1.2.3", "build": 1, "minimumOSVersion": "17.0", "releaseNotes": ["fixture"]}))
        self.write("Resources/Tracked.txt", "tagged contents")

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def run_command(self, *args, check=True):
        return subprocess.run(args, cwd=self.root, check=check, capture_output=True, text=True)

    def git(self, *args):
        return self.run_command("git", *args).stdout.strip()

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def package(self, *args, check=True):
        return self.run_command(sys.executable, "scripts/package-source.py", *args, check=check)

    def test_archive_uses_commit_for_members_version_and_bytes(self):
        tagged = self.commit("Tag snapshot")
        self.git("tag", "-a", "v1.2.3", "-m", "Fixture tag")
        self.write("Resources/Tracked.txt", "later committed contents")
        self.write("Configuration/Release.json", '{"version":"1.2.4"}')
        self.commit("Newer snapshot")
        self.write("Configuration/Release.json", '{"version":"9.9.9"}')
        self.write("Resources/Tracked.txt", "staged contents")
        self.write("staged.txt", "staged addition")
        self.git("add", "Resources/Tracked.txt", "staged.txt")
        self.write("Resources/Tracked.txt", "unstaged contents")
        for name in (".env", "Resources/.env.test", "Resources/developer.cer", "Resources/key.p12",
                     "Configuration/Local.xcconfig", "local/private.txt"):
            self.write(name, "ignored fixture")
            self.git("check-ignore", "-q", name)
        self.write("untracked-note.txt", "untracked by Git")

        self.package("--ref", "refs/tags/v1.2.3", "--expect-tag", "v1.2.3")
        output = self.root / "dist" / SOURCE
        with zipfile.ZipFile(output) as archive:
            expected = {"hongguo-ios/" + name for name in self.git("ls-tree", "-r", "--name-only", tagged).splitlines()}
            self.assertEqual(set(archive.namelist()), expected)
            self.assertEqual(archive.read("hongguo-ios/Resources/Tracked.txt"), b"tagged contents")
            self.assertEqual(json.loads(archive.read("hongguo-ios/Configuration/Release.json"))["version"], "1.2.3")
        digest = hashlib.sha256(output.read_bytes()).hexdigest()
        self.assertEqual(output.with_suffix(".zip.sha256").read_text(), f"{digest}  {SOURCE}\n")
        self.package("--ref", tagged)
        self.assertEqual(hashlib.sha256(output.read_bytes()).hexdigest(), digest)
        self.package()
        with zipfile.ZipFile(self.root / "dist/Hongguo-iOS-1.2.4-source.zip") as archive:
            self.assertEqual(archive.read("hongguo-ios/Resources/Tracked.txt"), b"later committed contents")
            self.assertNotIn("hongguo-ios/staged.txt", archive.namelist())
        self.assertFalse((self.root / "dist/Hongguo-iOS-9.9.9-source.zip").exists())

    def test_invalid_commits_do_not_create_or_replace_archives(self):
        good = self.commit("Baseline")
        self.package()
        output = self.root / "dist" / SOURCE
        original = output.read_bytes()
        for name in (".env", "Resources/Developer.CER", "local/private.txt", "Configuration/Local.xcconfig"):
            with self.subTest(name=name):
                self.write(name, "synthetic sensitive contents")
                self.git("add", "-f", "--", name)
                self.git("commit", "-qm", "Bad snapshot")
                result = self.package(check=False)
                self.assertIn("private path or signing material", result.stderr)
                self.assertNotIn("synthetic sensitive contents", result.stderr)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output.read_bytes(), original)
                self.git("rm", "-q", "--", name)
                self.git("commit", "-qm", "Remove fixture")
        (self.root / "unsafe-link").symlink_to("/tmp/nonexistent-packaging-fixture")
        self.commit("Add symlink")
        self.assertIn("symlink or submodule", self.package(check=False).stderr)
        self.assertIn("Tag disagrees", self.package("--ref", good, "--expect-tag", "v9.9.9", check=False).stderr)
        self.assertEqual(output.read_bytes(), original)

    def test_release_builds_snapshot_and_rejects_stale_artifacts(self):
        self.write("scripts/build-unsigned.sh", f"""#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
test ! -e .env
test ! -e Resources/Untracked.swift
test ! -e local
mkdir build dist
touch build/release-build.log
cp Resources/Tracked.txt dist/{IPA}
touch dist/{IPA}.sha256
""")
        self.write("scripts/test-feeds.py", "")
        self.write("scripts/verify-ipa.py", "")
        for name in ("update.json", "source.json", "source-cn.json", "source-cn-backup.json"):
            self.write("distribution/" + name, "{}")
        self.write("scripts/generate-feeds.py", """import sys
from pathlib import Path
if "--output" in sys.argv and "--check" not in sys.argv:
    output = Path(sys.argv[sys.argv.index("--output") + 1])
    for manifest in output.glob("*.json"):
        manifest.write_text('{"generated":true}')
""")
        self.commit("Release fixture")
        self.git("tag", "v1.2.3")
        self.git("tag", "v9.9.9")
        self.write(".env", "ignored fixture")
        self.write("local/private.txt", "ignored fixture")
        self.write("Resources/Untracked.swift", "untracked fixture")
        self.write("Resources/Tracked.txt", "dirty fixture")
        self.assertIn("clean index", self.run_command("bash", "scripts/release.sh", "v1.2.3", check=False).stderr)
        self.write("Resources/Tracked.txt", "tagged contents")
        self.assertIn("Tag disagrees", self.run_command("bash", "scripts/release.sh", "v9.9.9", check=False).stderr)
        self.run_command("bash", "scripts/release.sh", "v1.2.3")
        ipa = self.root / "dist" / IPA
        self.assertEqual(ipa.read_text(), "tagged contents")
        self.run_command("bash", "scripts/release.sh", "v1.2.3", "--skip-build")
        ipa.write_text("different IPA with the same version")
        self.assertIn("No matching prepared IPA", self.run_command(
            "bash", "scripts/release.sh", "v1.2.3", "--skip-build", check=False).stderr)
        self.write("Resources/Tracked.txt", "different commit")
        self.commit("Later commit, same version")
        self.assertIn("Check out the commit", self.run_command("bash", "scripts/release.sh", "v1.2.3", check=False).stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
