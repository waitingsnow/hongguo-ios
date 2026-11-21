"""Shared unsigned IPA validation for builds and feed generation."""
from __future__ import annotations

import hashlib
import plistlib
import re
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

from package_rules import ValidationError, archive_parts, private_path, require

BUNDLE_ID = "com.ooiua.hongguo.ios"
APP_PREFIX = "Payload/Hongguo.app/"


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_macho(binary: bytes, expected_minimum: str) -> None:
    require(len(binary) >= 32, "Missing/truncated Mach-O header")
    magic, cpu, _, file_type, commands, command_bytes, _, _ = struct.unpack_from("<8I", binary)
    require(magic == 0xFEEDFACF and cpu == 0x0100000C and file_type == 2, "Expected a thin arm64 device executable")
    require(commands <= 4096 and command_bytes <= len(binary) - 32, "Invalid Mach-O load-command table")
    position, device_platform = 32, False
    expected = tuple(int(item) for item in expected_minimum.split("."))
    expected = (expected + (0, 0))[:3]
    for _ in range(commands):
        require(position + 8 <= 32 + command_bytes, "Truncated Mach-O command")
        command, size = struct.unpack_from("<II", binary, position)
        require(size >= 8 and size % 4 == 0 and size <= 32 + command_bytes - position, "Invalid Mach-O command length")
        require(command != 0x1D, "Signed IPA rejected: LC_CODE_SIGNATURE is present")
        if command == 0x32:  # LC_BUILD_VERSION
            require(size >= 24, "Truncated LC_BUILD_VERSION")
            platform, minimum = struct.unpack_from("<II", binary, position + 8)
            require(platform == 2, "Simulator/non-iOS executable rejected")
            actual = ((minimum >> 16) & 0xFFFF, (minimum >> 8) & 0xFF, minimum & 0xFF)
            require(actual == expected, "Mach-O deployment target disagrees with Release.json")
            device_platform = True
        position += size
    require(position == 32 + command_bytes and device_platform, "Missing/invalid device build-version command")


def validate_entries(archive):
    entries = archive.infolist()
    require(len(entries) <= 20000 and sum(entry.file_size for entry in entries) <= 1024 * 1024 * 1024,
            "IPA archive exceeds validation limits")
    spellings = {}
    kinds = {}
    names = set()
    for entry in entries:
        require(entry.orig_filename == entry.filename, "Unsafe archive path")
        parts = archive_parts(entry.filename)
        original = entry.filename.removesuffix("/").split("/")
        require(entry.filename not in names, "Duplicate archive paths rejected")
        require(not stat.S_ISLNK(entry.external_attr >> 16), "Archive symlinks rejected")
        require(not private_path(parts) and not parts[-1].endswith(".entitlements"),
                "Private paths or signing material rejected in IPA")
        for length in range(1, len(parts) + 1):
            path = parts[:length]
            spelling = original[:length]
            directory = length < len(parts) or entry.is_dir()
            require(spellings.setdefault(path, spelling) == spelling and kinds.setdefault(path, directory) == directory,
                    "Conflicting archive paths rejected")
        names.add(entry.filename)
    return names


def validate_ipa(path: Path, config: dict, *, use_codesign: bool = True, check_new_build=None) -> dict:
    require(path.is_file(), "IPA file does not exist")
    require(path.name == f"Hongguo-iOS-{config['version']}-unsigned.ipa", "IPA filename disagrees with release version")
    require(path.stat().st_size > 0, "IPA is empty")
    try:
        with zipfile.ZipFile(path) as archive:
            names = validate_entries(archive)
            require(archive.testzip() is None, "IPA archive CRC verification failed")
            info_names = {name for name in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)}
            require(info_names == {APP_PREFIX + "Info.plist"}, "Expected exactly Payload/Hongguo.app")
            info = plistlib.loads(archive.read(APP_PREFIX + "Info.plist"))
            require(info.get("CFBundleIdentifier") == BUNDLE_ID, "Unexpected bundle identifier")
            require(info.get("CFBundleShortVersionString") == config["version"], "IPA version disagrees with Release.json")
            require(info.get("CFBundleVersion") == str(config["build"]), "IPA build disagrees with Release.json")
            require(info.get("MinimumOSVersion") == config["minimumOSVersion"], "IPA minimum OS disagrees with Release.json")
            require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "Expected iPhoneOS package")
            executable = info.get("CFBundleExecutable")
            require(isinstance(executable, str) and re.fullmatch(r"[A-Za-z0-9_.-]+", executable) is not None,
                    "Invalid bundle executable")
            for resource in ("PureSign.js", "BufferRuntime.js", "Assets.car"):
                require(APP_PREFIX + resource in names, f"Required packaged resource missing: {resource}")
            binary_name = APP_PREFIX + executable
            inspect_macho(archive.read(binary_name), config["minimumOSVersion"])
            if check_new_build is not None:
                check_new_build(archive, binary_name, info, config)
            if use_codesign and sys.platform == "darwin":
                with tempfile.TemporaryDirectory(prefix="hongguo-ipa-verify-") as folder:
                    archive.extractall(folder)
                    command = subprocess.run(["/usr/bin/codesign", "-dv", str(Path(folder) / APP_PREFIX)],
                                             capture_output=True, text=True, check=False)
                    require(command.returncode != 0 and "not signed at all" in command.stderr,
                            "codesign did not confirm an unsigned app")
    except (zipfile.BadZipFile, KeyError, plistlib.InvalidFileException, struct.error, OSError) as error:
        raise ValidationError("Invalid IPA: " + type(error).__name__) from error
    return {"version": config["version"], "build": config["build"], "minimumOSVersion": config["minimumOSVersion"],
            "sdk": info.get("DTPlatformVersion", "0"),
            "bundleIdentifier": BUNDLE_ID, "sha256": file_sha256(path), "size": path.stat().st_size, "unsigned": True}
