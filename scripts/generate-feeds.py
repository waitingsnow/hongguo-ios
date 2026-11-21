#!/usr/bin/env python3
"""Generate QNQ feeds and the update manifest only from a validated unsigned device IPA."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
from pathlib import Path

from ipa_checks import BUNDLE_ID, file_sha256, validate_ipa
from package_rules import ValidationError, require

ROOT = Path(__file__).resolve().parent.parent
MIRRORS = {"gh-proxy": "https://gh-proxy.com/", "ghfast": "https://ghfast.top/"}
GENERATED = ("update.json", "source.json", "source-cn.json", "source-cn-backup.json")


def read_config(path: Path, tag: str | None = None) -> dict:
    config = json.loads(path.read_text(encoding="utf-8"))
    require(isinstance(config, dict), "Release.json must be an object")
    require(isinstance(config.get("version"), str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", config["version"]) is not None,
            "version must be a stable numeric X.Y.Z version")
    require(type(config.get("build")) is int and config["build"] > 0, "build must be a positive integer")
    require(isinstance(config.get("repository"), str) and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", config["repository"]) is not None,
            "repository must be owner/name")
    require(isinstance(config.get("minimumOSVersion"), str) and re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", config["minimumOSVersion"]) is not None,
            "minimumOSVersion must be a numeric OS version")
    require(isinstance(config.get("releaseNotes"), list) and bool(config["releaseNotes"]) and
            all(isinstance(item, str) and item.strip() for item in config["releaseNotes"]), "releaseNotes must contain nonempty strings")
    if tag is not None:
        require(tag == "v" + config["version"], "Tag does not match Configuration/Release.json")
    return config


def timestamp(value: str | None = None) -> str:
    if value is None:
        return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValidationError("publishedAt must be an ISO8601 timestamp") from error
    require(parsed.utcoffset() is not None, "publishedAt must include a timezone")
    return parsed.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def make_documents(config: dict, actual: dict, published_at: str) -> dict[str, dict]:
    version, repository = config["version"], config["repository"]
    download = f"https://github.com/{repository}/releases/download/v{version}/Hongguo-iOS-{version}-unsigned.ipa"
    raw = f"https://raw.githubusercontent.com/{repository}/main/distribution/"
    icon_url = f"https://raw.githubusercontent.com/{repository}/v{version}/distribution/icon.png"
    mirrors = {name: prefix + download for name, prefix in MIRRORS.items()}
    update = {"version": version, "build": config["build"], "minimumOSVersion": config["minimumOSVersion"],
              "releaseNotes": config["releaseNotes"], "publishedAt": published_at, "downloadURL": download,
              "sha256": actual["sha256"], "size": actual["size"], "mirrors": mirrors}
    documents = {"update.json": update}
    routes = [("source.json", "GitHub 直连", "", download),
              ("source-cn.json", "国内加速", MIRRORS["gh-proxy"], mirrors["gh-proxy"]),
              ("source-cn-backup.json", "国内备用加速", MIRRORS["ghfast"], mirrors["ghfast"])]
    for name, title, proxy, address in routes:
        icon = proxy + icon_url
        app = {"name": "红果独立版", "type": "1", "bundleIdentifier": BUNDLE_ID,
               "version": version, "build": config["build"], "minimumOSVersion": config["minimumOSVersion"],
               "versionDate": published_at, "versionDescription": "\n".join(config["releaseNotes"]) + "\n未签名 IPA，需使用本人的证书签名后安装。",
               "lock": "0", "downloadURL": address, "isLanZouCloud": "0", "iconURL": icon,
               "tintColor": "E8463F", "size": str(actual["size"]), "sha256": actual["sha256"]}
        documents[name] = {"name": "红果 iOS · " + title,
                           "message": "项目维护者发布的未签名 IPA；需要自行签名安装。" + ("加速服务由第三方提供。" if proxy else ""),
                           "identifier": repository.lower().replace("/", ".") + "." + name.removesuffix(".json"),
                           "sourceURL": proxy + raw + name, "sourceicon": icon, "apps": [app]}
    return documents


def generate(config_path: Path, ipa: Path, output: Path, *, tag: str | None = None, published_at: str | None = None,
             check: bool = False, use_codesign: bool = True) -> dict:
    config = read_config(config_path, tag)
    actual = validate_ipa(ipa, config, use_codesign=use_codesign)
    icon = output / "icon.png"
    require(icon.is_file() and icon.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), "distribution/icon.png must be a PNG")
    if check and published_at is None:
        published_at = json.loads((output / "update.json").read_text(encoding="utf-8"))["publishedAt"]
    documents = make_documents(config, actual, timestamp(published_at))
    if check:
        for name, expected in documents.items():
            require(json.loads((output / name).read_text(encoding="utf-8")) == expected, "Generated metadata differs from validated IPA/config: " + name)
    else:
        output.mkdir(parents=True, exist_ok=True)
        for name, document in documents.items():
            data = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
            temporary = output / (name + ".tmp")
            temporary.write_text(data, encoding="utf-8")
            os.replace(temporary, output / name)
    return actual


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=ROOT / "Configuration/Release.json")
    parser.add_argument("--ipa", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "distribution")
    parser.add_argument("--tag")
    parser.add_argument("--published-at")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--config-only", action="store_true")
    args = parser.parse_args()
    try:
        config = read_config(args.config, args.tag)
        if args.config_only:
            print(json.dumps(config, ensure_ascii=False)); return
        ipa = args.ipa or ROOT / f"dist/Hongguo-iOS-{config['version']}-unsigned.ipa"
        actual = generate(args.config, ipa, args.output, tag=args.tag, published_at=args.published_at, check=args.check)
        print(json.dumps(actual, ensure_ascii=False, indent=2))
    except (ValidationError, ValueError, OSError) as error:
        parser.exit(1, f"Feed validation failed: {error}\n")


if __name__ == "__main__":
    main()
