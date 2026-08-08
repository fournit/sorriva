// swift-tools-version: 5.9
import PackageDescription

// FastTests — the simulator-free test loop for Sorriva's pure logic.
//
// WHY THIS EXISTS
// The Xcode test target is *hosted*: TEST_HOST points at Sorriva.app, so running
// even one test builds the whole app, boots a simulator, installs and launches it.
// Measured 2026-08-08: ~600 seconds. That is slow enough that you stop running
// tests, which is the actual failure — a suite you skip protects nothing.
//
// The logic under test here has no UI and no iOS in it. It takes bytes in and
// returns answers. So it is compiled for macOS and run directly: 1.35 seconds.
//
// THE FILES ARE SYMLINKS, NOT COPIES. Tests/FastTests/ArtworkLookup.swift points
// at ../../../Sorriva/ArtworkLookup.swift. There is one file on disk, compiled by
// both the app and this package. A copy could pass while the shipping code had
// moved on, which is worse than having no test at all; a symlink cannot.
//
// The test files are symlinked too, so they still run in the full Xcode suite.
// This package is the fast path, not a replacement. Nothing was removed from the
// Xcode project to build it.
//
// WHAT MAY LIVE HERE: files importing only Foundation. The moment one of these
// needs SwiftUI or UIKit, this package stops compiling — loudly, at build time.
// That is the intended behaviour, not a bug to work around: it means the file has
// grown a UI dependency and belongs on the hosted side.

let package = Package(
    name: "FastTests",
    platforms: [.macOS(.v13)],
    targets: [
        .testTarget(
            name: "FastTests",
            path: "Tests/FastTests"
        )
    ]
)
