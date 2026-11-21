#!/bin/bash
# Prepare a validated release locally. Publication and Git pushes are separate explicit steps.
set -euo pipefail
release_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$release_root"
release_tag="${1:-}"
release_mode="${2:-}"
if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || ( -n "$release_mode" && "$release_mode" != "--skip-build" ) ]]; then
  echo "Usage: scripts/release.sh vX.Y.Z [--skip-build]" >&2
  echo "Use --skip-build to verify artifacts previously prepared by this script for the same tag." >&2
  exit 2
fi
release_commit="$(git --no-replace-objects rev-parse --verify "refs/tags/$release_tag^{commit}")"
if [[ "$release_commit" != "$(git --no-replace-objects rev-parse HEAD)" ]]; then
  echo "Check out the commit for $release_tag before preparing the release." >&2
  exit 1
fi
if [[ "$release_mode" == "--skip-build" ]]; then
  release_changes="$(git status --porcelain --untracked-files=no -- . \
    ':(exclude)distribution/update.json' ':(exclude)distribution/source.json' \
    ':(exclude)distribution/source-cn.json' ':(exclude)distribution/source-cn-backup.json')"
else
  release_changes="$(git status --porcelain --untracked-files=no)"
fi
if [[ -n "$release_changes" ]]; then
  echo "Release preparation requires a clean index and tracked working tree." >&2
  exit 1
fi

release_version="${release_tag#v}"
release_ipa="Hongguo-iOS-${release_version}-unsigned.ipa"
release_source="Hongguo-iOS-${release_version}-source.zip"
release_temp="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-release.XXXXXX")"
trap 'rm -rf "$release_temp"' EXIT
python3 scripts/package-source.py --ref "$release_commit" --expect-tag "$release_tag" --output-dir "$release_temp"

release_inputs() {
  printf '%s\n' "$release_commit"
  /usr/bin/shasum -a 256 < "$1"
}

if [[ "$release_mode" == "--skip-build" ]]; then
  if ! release_inputs "dist/$release_ipa" > "$release_temp/inputs" ||
     ! cmp -s "$release_temp/inputs" build/release-inputs ||
     ! cmp -s "$release_temp/$release_source" "dist/$release_source"; then
    echo "No matching prepared IPA and source archive for $release_tag. Run without --skip-build." >&2
    exit 1
  fi
  /usr/bin/unzip -q "$release_temp/$release_source" hongguo-ios/Configuration/Release.json -d "$release_temp"
  release_config="$release_temp/hongguo-ios/Configuration/Release.json"
  python3 scripts/verify-ipa.py "dist/$release_ipa" --config "$release_config"
  python3 scripts/generate-feeds.py --tag "$release_tag" --config "$release_config" --check
  exit 0
fi

python3 scripts/test-feeds.py
/usr/bin/unzip -q "$release_temp/$release_source" -d "$release_temp"
release_snapshot="$release_temp/hongguo-ios"
release_config="$release_snapshot/Configuration/Release.json"
release_built_ipa="$release_snapshot/dist/$release_ipa"
mkdir -p build
if ! bash "$release_snapshot/scripts/build-unsigned.sh"; then
  if [[ -f "$release_snapshot/build/release-build.log" ]]; then
    cp "$release_snapshot/build/release-build.log" build/release-build.log
  fi
  exit 1
fi
cp "$release_snapshot/build/release-build.log" build/release-build.log
python3 scripts/verify-ipa.py "$release_built_ipa" --config "$release_config"
python3 scripts/generate-feeds.py --tag "$release_tag" --config "$release_config" \
  --ipa "$release_built_ipa" --output "$release_snapshot/distribution"
python3 scripts/generate-feeds.py --tag "$release_tag" --config "$release_config" \
  --ipa "$release_built_ipa" --output "$release_snapshot/distribution" --check
release_inputs "$release_built_ipa" > "$release_temp/inputs"
mkdir -p dist
cp "$release_built_ipa" "${release_built_ipa}.sha256" "$release_temp/$release_source" \
  "$release_temp/${release_source}.sha256" dist/
for release_file in update.json source.json source-cn.json source-cn-backup.json; do
  cp "$release_snapshot/distribution/$release_file" "distribution/$release_file"
done
mv "$release_temp/inputs" build/release-inputs
python3 - "$release_config" "$release_ipa" <<'PY'
import json, sys
from pathlib import Path
config = json.loads(Path(sys.argv[1]).read_text())
notes = '\n'.join('- ' + item for item in config['releaseNotes'])
Path('build/release-notes.md').write_text(f"红果 iOS {config['version']}（build {config['build']}）\n\n{notes}\n\n未签名 IPA，需要自行签名后安装。最低 iOS {config['minimumOSVersion']}。\n")
print(f"Prepared {sys.argv[2]}; feeds are in distribution/. No release or commit was created.")
PY
