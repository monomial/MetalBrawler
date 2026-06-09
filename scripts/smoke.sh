#!/usr/bin/env bash
# Visual smoke test: build the macOS app, let AutoPilot play a full run, and
# collect screenshots of every key beat. Exit code: 0 = bot won, 1 = timeout,
# 2 = bot lost. Screenshots land in $OUT for visual review.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/brawler-autotest}"
rm -rf "$OUT"
mkdir -p "$OUT"

xcodebuild -project MetalBrawler.xcodeproj -scheme Brawler-macOS \
           -destination 'platform=macOS' -derivedDataPath .build/DerivedData \
           build -quiet

APP=".build/DerivedData/Build/Products/Debug/Brawler-macOS.app/Contents/MacOS/Brawler-macOS"

# Clear DYLD_LIBRARY_PATH — inherited from Node it confuses the dynamic linker.
set +e
env -u DYLD_LIBRARY_PATH "$APP" --autotest "--autotest-out=$OUT"
status=$?
set -e

echo "smoke: exit=$status"
ls -l "$OUT"
exit $status
