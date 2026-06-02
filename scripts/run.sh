#!/usr/bin/env bash
# Run the debug macOS build with a clean dyld environment.
# Claude Code's shell inherits DYLD_LIBRARY_PATH from Node.js which confuses
# the macOS dynamic linker when launching a native Metal app.
APP=".build/DerivedData/Build/Products/Debug/Brawler-macOS.app/Contents/MacOS/Brawler-macOS"
exec env -u DYLD_LIBRARY_PATH "$APP" "$@"
