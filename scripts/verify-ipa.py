#!/usr/bin/env python3
"""Verify a newly built unsigned device IPA and reject private build paths."""
import argparse
import json
import re
import struct
from pathlib import Path

from ipa_checks import APP_PREFIX, validate_ipa
from package_rules import ValidationError, require

ROOT = Path(__file__).resolve().parent.parent
ABSOLUTE = rb"(?<![A-Za-z0-9_./\\-])"
POSIX_END = rb"(?=[/\s\x00\"']|$)"
HOME_PATHS = {
    "macOS home": re.compile(ABSOLUTE + rb"(?:/System/Volumes/Data)?/Users/(?!Shared"
                             + POSIX_END + rb")[^/\s\x00\"']{1,255}" + POSIX_END),
    "macOS root home": re.compile(ABSOLUTE + rb"(?:/private)?/var/root" + POSIX_END),
    "Linux home": re.compile(ABSOLUTE + rb"/home/[^/\s\x00\"']{1,255}" + POSIX_END),
    "Linux root home": re.compile(ABSOLUTE + rb"/root" + POSIX_END),
    "Windows home": re.compile(ABSOLUTE + rb"[A-Z]:[\\/]Users[\\/][^\\/\x00\r\n\"']{1,255}(?=[\\/\x00\r\n\"']|$)",
                               re.IGNORECASE),
}
PEM = re.compile(rb"(?:^|\n)-----BEGIN (?:[A-Z0-9 ]*PRIVATE KEY|CERTIFICATE(?: REQUEST)?|PKCS12)-----\r?\n[A-Za-z0-9+/]")
MACHO_MAGICS = {bytes.fromhex(magic) for magic in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}
SCAN_CHUNK_BYTES = 64 * 1024
SCAN_CONTEXT_BYTES = 512
OPENHONGGUO_GO_REPLACEMENTS = tuple(
    re.compile(
        re.escape(b"\ndep\tgithub.com/beilunyang/openhongguo" + suffix + b"\t" + version + b"\n=>\t")
        + b"(" + re.escape(b"/Users/runner/work/openhongguo/openhongguo" + suffix) + b")"
        + re.escape(b"\t(devel)\t\n")
    )
    for suffix, version in (
        (b"", b"v0.0.0"),
        (b"/bindings/mobile/core", b"v0.0.0-00010101000000-000000000000"),
    )
)


def version_tuple(text):
    return tuple(int(part) for part in str(text).split("."))


def check_new_build(archive, executable, info, config):
    sdk = info.get("DTPlatformVersion", "0")
    require(version_tuple(sdk) >= version_tuple(config["minimumBuildSDK"]),
            f"iPhone Duo needs iOS SDK {config['minimumBuildSDK']} or later")
    require(APP_PREFIX + "PlayerSignV5.js" in archive.namelist(), "Required packaged resource missing: PlayerSignV5.js")
    for entry in archive.infolist():
        require(not entry.extra, "ZIP central-directory extra fields detected in IPA")
        archive.fp.seek(entry.header_offset)
        header = archive.fp.read(30)
        require(len(header) == 30 and header.startswith(b"PK\x03\x04"), "Invalid ZIP local header in IPA")
        require(struct.unpack_from("<H", header, 28)[0] == 0, "ZIP local-header extra fields detected in IPA")
        if entry.is_dir():
            continue
        with archive.open(entry) as stream:
            is_executable = entry.filename == executable
            chunk = stream.read(SCAN_CHUNK_BYTES)
            require(is_executable or chunk[:4] not in MACHO_MAGICS,
                    "Unexpected embedded Mach-O in unsigned IPA")
            tail = b""
            while chunk:
                following = stream.read(SCAN_CHUNK_BYTES)
                start = len(tail)
                end = start + len(chunk)
                window = tail + chunk + following[:SCAN_CONTEXT_BYTES]
                public_paths = {
                    record.start(1)
                    for replacement in OPENHONGGUO_GO_REPLACEMENTS
                    for record in replacement.finditer(window)
                } if is_executable else set()
                for kind, pattern in HOME_PATHS.items():
                    require(not any(match.start() < end and match.start() not in public_paths
                                    for match in pattern.finditer(window, start)),
                            f"Private absolute home path detected ({kind})")
                require(PEM.search(window) is None, "PEM signing material detected in IPA")
                tail = chunk[-SCAN_CONTEXT_BYTES:]
                chunk = following


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path, nargs="?")
    parser.add_argument("--config", type=Path, default=ROOT / "Configuration/Release.json")
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text(encoding="utf-8"))
        ipa = args.ipa or ROOT / f"dist/Hongguo-iOS-{config['version']}-unsigned.ipa"
        report = validate_ipa(ipa, config, check_new_build=check_new_build)
    except ValidationError as error:
        parser.exit(1, f"IPA verification failed: {error}\n")
    except (KeyError, ValueError, OSError, RuntimeError) as error:
        parser.exit(1, f"IPA verification failed: {type(error).__name__}\n")
    print(json.dumps({"ipa": ipa.name, "bytes": report["size"], "version": report["version"],
                      "build": str(report["build"]), "bundle_identifier": report["bundleIdentifier"],
                      "minimum_ios": report["minimumOSVersion"], "sdk": report["sdk"], "platform": "iPhoneOS",
                      "architecture": "arm64", "unsigned": True, "playback_resources_present": True,
                      "sha256": report["sha256"]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
