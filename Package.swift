// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "DesktopDeck", platforms: [.macOS("26.0")],
    products: [.executable(name: "DesktopDeck", targets: ["DesktopDeck"]),
               .executable(name: "desktop-deck-mcp", targets: ["DeckMCP"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.3"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(name: "CVNC", cSettings: [.headerSearchPath("../../.native/include")],
                linkerSettings: [.unsafeFlags(["-L.native/lib"]), .linkedLibrary("vncclient"),
                    .linkedLibrary("jpeg"), .linkedLibrary("ssl"), .linkedLibrary("crypto"), .linkedLibrary("z")]),
        .target(name: "DeckCore"),
        .executableTarget(name: "DesktopDeck", dependencies: ["DeckCore", "CVNC", "SwiftTerm"],
                          linkerSettings: [.linkedFramework("MetalKit"), .linkedFramework("Security")]),
        .executableTarget(name: "DeckMCP", dependencies: ["DeckCore", .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "DeckCoreTests", dependencies: ["DeckCore"])
    ], swiftLanguageModes: [.v5])
