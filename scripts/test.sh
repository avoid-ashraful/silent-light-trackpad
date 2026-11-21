#!/bin/sh
# Run the test suite. With full Xcode installed, plain `swift test`
# runs everything (XCTest + Swift Testing). With only the Command Line
# Tools, XCTest is unavailable (those suites compile out via
# `#if canImport(XCTest)`) and SwiftPM fails to locate the Swift
# Testing macro plugin, so load it explicitly.
set -e
cd "$(dirname "$0")/.."
PLUGIN="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$PLUGIN" ] && ! xcrun --find xctest >/dev/null 2>&1; then
  exec swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" "$@"
fi
exec swift test "$@"
