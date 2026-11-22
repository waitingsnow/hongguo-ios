#!/bin/bash
set -euo pipefail
if [[ $# != 1 ]]; then
    echo "Usage: bash scripts/test-playback-continuity.sh BOOTED_SIMULATOR_UDID" >&2
    exit 2
fi
cd "$(dirname "$0")/.."
derived="$PWD/build/qa-continuity"
packages="$PWD/build/DerivedData/SourcePackages"
products="$derived/Build/Products/Debug-iphonesimulator"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-continuity.XXXXXX")"
trap 'rm -r "$scratch"' EXIT
xcodebuild -project Hongguo-QA.xcodeproj -scheme HongguoQA -configuration Debug \
    -destination "platform=iOS Simulator,id=$1" -derivedDataPath "$derived" \
    -clonedSourcePackagesDirPath "$packages" build-for-testing -quiet
ffmpeg -v error -f lavfi -i testsrc2=size=320x180:rate=24 -t 14 -an -c:v libx264 \
    -pix_fmt yuv420p -movflags +faststart "$scratch/fixture.mp4"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
for probe in PlaybackContinuityProbe PlaybackRevisitProbe; do
    xcrun --sdk iphonesimulator swiftc -parse-as-library -target "$(uname -m)-apple-ios17.0-simulator" \
        -sdk "$sdk" -I "$products" -F "$products/PackageFrameworks" \
        -Xlinker -rpath -Xlinker "$products/Hongguo.app" "$products/Hongguo.app/Hongguo.debug.dylib" \
        "Tests/$probe.swift" -o "$scratch/probe"
    xcrun simctl spawn "$1" "$scratch/probe" "$scratch/fixture.mp4"
done
