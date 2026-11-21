#!/usr/bin/env python3
"""Archive committed files from --ref (default HEAD). Index and worktree changes are ignored."""
import argparse
import hashlib
import json
import re
import subprocess
import tempfile
import zipfile
from pathlib import Path

from package_rules import ValidationError, archive_parts, private_path, require

ROOT = Path(__file__).resolve().parent.parent


def git(*args):
    return subprocess.check_output(["git", "--no-replace-objects", "-C", str(ROOT), *args])


def snapshot(commit):
    files = []
    seen = {}
    for entry in git("ls-tree", "-rz", commit).split(b"\0")[:-1]:
        metadata, name = entry.split(b"\t", 1)
        mode, kind, oid = metadata.decode("ascii").split()
        parts = archive_parts(name.decode("utf-8"))
        require(not private_path(parts), "Commit contains a private path or signing material")
        require(kind == "blob" and mode in {"100644", "100755"},
                "Source snapshot contains a symlink or submodule")
        for length in range(1, len(parts) + 1):
            path = b"/".join(name.split(b"/")[:length])
            require(seen.setdefault(parts[:length], path) == path, "Conflicting source archive paths")
        files.append((name.decode("utf-8"), mode, oid))
    return files


def package(ref, output_dir, expected_tag):
    commit = git("rev-parse", "--verify", "--end-of-options", ref + "^{commit}").decode("ascii").strip()
    files = snapshot(commit)
    config = json.loads(git("show", commit + ":Configuration/Release.json"))
    version = config.get("version")
    require(isinstance(version, str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version),
            "Expected a numeric X.Y.Z in committed Release.json")
    require(expected_tag is None or expected_tag == "v" + version, "Tag disagrees with committed Release.json")
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"Hongguo-iOS-{version}-source.zip"
    with tempfile.TemporaryDirectory(prefix=".source-", dir=output_dir) as temporary:
        staged = Path(temporary) / output.name
        with zipfile.ZipFile(staged, "w") as archive:
            for name, mode, oid in files:
                item = zipfile.ZipInfo("hongguo-ios/" + name)
                item.create_system = 3
                item.external_attr = int(mode, 8) << 16
                archive.writestr(item, git("cat-file", "blob", oid), zipfile.ZIP_DEFLATED)
        digest = hashlib.sha256(staged.read_bytes()).hexdigest()
        checksum = output.with_suffix(".zip.sha256")
        staged_checksum = Path(temporary) / checksum.name
        staged_checksum.write_text(f"{digest}  {output.name}\n", encoding="ascii")
        staged.replace(output)
        staged_checksum.replace(checksum)
    print(f"Source archive: {output.name} ({len(files)} files) from {commit}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default="HEAD", help="Git tag or commit to archive")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    parser.add_argument("--expect-tag", help="Require vX.Y.Z to match the snapshot's Release.json")
    args = parser.parse_args()
    try:
        package(args.ref, args.output_dir, args.expect_tag)
    except (ValidationError, OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Source packaging failed: {error}\n")


if __name__ == "__main__":
    main()
