// swift-tools-version:5.9
import PackageDescription
import Foundation

// libgphoto2: the copy built for macOS 13+ by scripts/build_deps.sh when it is there (release
// builds), otherwise Homebrew's.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let deps = packageDir + "/.deps/prefix"
let gphotoPrefix = FileManager.default.fileExists(atPath: deps + "/include/gphoto2") ? deps : "/opt/homebrew"

let package = Package(
    name: "TetherStudio",
    platforms: [.macOS(.v13)],
    targets: [
        // Thin C wrapper around libgphoto2: owns all Camera*/GPContext*/widget
        // types internally, exposes void* handles + plain C types to Swift
        // (the Swift/clang importer won't surface gphoto2's opaque typedefs).
        .target(
            name: "GPhotoC",
            path: "Sources/GPhotoC",
            cSettings: [
                .unsafeFlags(["-I\(gphotoPrefix)/include"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(gphotoPrefix)/lib", "-lgphoto2", "-lgphoto2_port", "-lm"]),
            ]
        ),
        .executableTarget(
            name: "TetherStudio",
            dependencies: ["GPhotoC"],
            path: "Sources/TetherStudio"
        ),
        .testTarget(
            name: "TetherStudioTests",
            dependencies: ["TetherStudio"],
            path: "Tests/TetherStudioTests"
        ),
    ]
)
