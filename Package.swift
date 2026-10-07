// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Daybook",
    platforms: [.macOS(.v26), .iOS(.v26)],
    // DaybookCore is shared with the iPhone app (Daybook.xcodeproj).
    products: [.library(name: "DaybookCore", targets: ["DaybookCore"])],
    targets: [
        // Everything testable without calendar access: the daily summary,
        // quick-add parsing, and grouping events into days.
        .target(name: "DaybookCore"),
        .executableTarget(name: "Daybook", dependencies: ["DaybookCore"]),
        .testTarget(name: "DaybookCoreTests", dependencies: ["DaybookCore"]),
    ]
)
