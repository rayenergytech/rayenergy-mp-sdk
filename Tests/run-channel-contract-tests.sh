#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mp-channel-contract.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
cat > "$scratch/main.swift" <<'SWIFT'
import Foundation
let context=RuleContext()
let old=context.snapshot(deviceLanguage:"en")
precondition(old["channel"]=="organic")
context.patch(["channel":" meta_ads "])
precondition(context.snapshot(deviceLanguage:nil)["channel"]=="meta_ads")
precondition(old["channel"]=="organic")
context.patch(["channel":"google_ads"])
precondition(context.snapshot(deviceLanguage:nil)["channel"]=="google_ads")
for alias in ["web","ogannic","ORGANIC","unknown"] {
 context.patch(["channel":alias]);precondition(context.snapshot(deviceLanguage:nil)["channel"]=="organic")
}
context.patch(["channel":NSNull()]);precondition(context.snapshot(deviceLanguage:nil)["channel"]=="organic")
_ = context.replaceCommon(["channel":"new_ad","campaign":"keep"])
precondition(context.snapshot(deviceLanguage:nil)["channel"]=="new_ad")
_ = context.replaceCommon([:]);precondition(context.snapshot(deviceLanguage:nil)["channel"]=="organic")
print("CHANNEL_CONTRACT_PASSED lateSource=true oldSnapshotUnchanged=true clearAndAliases=true")
SWIFT
swiftc -module-cache-path "$scratch/modules" "$root/Sources/MpTracker/RuleContext.swift" "$root/Sources/MpTracker/AcquisitionChannel.swift" "$scratch/main.swift" -o "$scratch/contract"
"$scratch/contract"
