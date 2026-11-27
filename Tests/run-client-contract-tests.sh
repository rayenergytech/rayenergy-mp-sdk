#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mp-client-contract.XXXXXX")
cache="${MP_CLIENT_CONTRACT_CACHE:-${TMPDIR:-/tmp}/mp-client-contract-cache}"
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/Sources/MpTracker" "$scratch/Sources/ClientContractTests"
cp "$root/Sources/MpTracker/MpClient.swift" "$root/Sources/MpTracker/RuleContext.swift" "$root/Sources/MpTracker/AcquisitionChannel.swift" "$root/Sources/MpTracker/Reporter.swift" "$scratch/Sources/MpTracker/"
cp "$root/Tests/ClientContractSupport/PlatformStandIns.swift" "$scratch/Sources/MpTracker/"
cp "$root/Tests/ClientContractTests/"*.swift "$scratch/Sources/ClientContractTests/"
cat > "$scratch/Package.swift" <<'SWIFT'
// swift-tools-version:5.7
import PackageDescription
let package = Package(name: "MpClientContract", platforms: [.macOS(.v12)], targets: [
    .target(name: "MpTracker"),
    .executableTarget(name: "ClientContractTests", dependencies: ["MpTracker"])
])
SWIFT
CLANG_MODULE_CACHE_PATH="$cache/modules" SWIFTPM_MODULECACHE_OVERRIDE="$cache/modules" \
    swift run --package-path "$scratch" --scratch-path "$scratch/build" \
    --cache-path "$cache/manifests" --config-path "$scratch/config" --security-path "$scratch/security" \
    --disable-sandbox
