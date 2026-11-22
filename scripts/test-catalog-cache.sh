#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hongguo-catalog-cache.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
package_dir="${1:-$project_dir/build/DerivedData/SourcePackages/checkouts/Nuke}"
if [[ ! -f "$package_dir/Package.swift" ]]; then
  xcodebuild -resolvePackageDependencies -project "$project_dir/Hongguo.xcodeproj" -scheme Hongguo \
    -clonedSourcePackagesDirPath "$work_dir/SourcePackages" -derivedDataPath "$work_dir/DerivedData"
  package_dir="$work_dir/SourcePackages/checkouts/Nuke"
fi
package_dir="$(cd "$package_dir" && pwd)"
mkdir "$work_dir/CatalogCacheTests"
ln -s "$package_dir" "$work_dir/Nuke"
cp "$project_dir/Sources/Core/Models.swift" "$project_dir/Sources/Core/HGCrypto.swift" \
   "$project_dir/Sources/Media/MP4Processor.swift" "$project_dir"/Sources/Networking/*.swift \
   "$project_dir/Sources/UI/ContentCache.swift" "$project_dir/Tests/CatalogCacheSelfTest.swift" \
   "$work_dir/CatalogCacheTests"
cat > "$work_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CatalogCacheTests",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "Nuke")],
    targets: [.executableTarget(
        name: "CatalogCacheTests",
        dependencies: [.product(name: "Nuke", package: "Nuke")],
        path: "CatalogCacheTests",
        linkerSettings: [.linkedLibrary("z"), .linkedFramework("JavaScriptCore")]
    )],
    swiftLanguageModes: [.v5]
)
SWIFT
xcrun swift run --package-path "$work_dir" CatalogCacheTests
