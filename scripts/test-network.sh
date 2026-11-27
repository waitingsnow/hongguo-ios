#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-network-test.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
mkdir "$work_dir/Sources"
ln -s \
  "$project_dir/Sources/Core/Models.swift" "$project_dir/Sources/Core/HGCrypto.swift" \
  "$project_dir/Sources/Media/MP4Processor.swift" "$project_dir"/Sources/Networking/*.swift \
  "$project_dir/Sources/Networking/Discussion/EpisodeDanmakuAPI.swift" \
  "$project_dir/Sources/Danmaku/DanmakuRepository.swift" "$project_dir/Sources/Danmaku/DanmakuLoader.swift" \
  "$project_dir/Sources/Danmaku/DanmakuPrefs.swift" "$project_dir/Sources/Danmaku/DanmakuEmoji.swift" \
  "$project_dir/Tests/NetworkSelfTest.swift" "$project_dir/Tests/DanmakuChecks.swift" \
  "$project_dir/Tests/PlaybackRecoveryChecks.swift" \
  "$project_dir/Tests/PublicEpisodeSourceChecks.swift" \
  "$project_dir/Tests/MobilePlaybackChecks.swift" "$work_dir/Sources"
cat > "$work_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HongguoNetworkTests",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/beilunyang/openhongguo.git", exact: "0.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "HongguoNetworkTests",
            dependencies: [.product(name: "Openhongguo", package: "openhongguo")],
            path: "Sources",
            linkerSettings: [.linkedLibrary("z"), .linkedFramework("JavaScriptCore")]
        ),
    ]
)
SWIFT
xcrun swift run --package-path "$work_dir" HongguoNetworkTests "$project_dir" "$work_dir"
if command -v node >/dev/null 2>&1; then
  node "$project_dir/Tests/signing-oracle.cjs"
fi
