// swift-tools-version: 6.1
// FXVaultKit: every non-UI module of FX Vault (tasks/todo.md §3, §4.2).
// The app links the `FXVaultKit` product only and never imports GRDB or Clibsodium.
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility"),
]

let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")
let clibsodium: Target.Dependency = .product(name: "Clibsodium", package: "swift-sodium")

/// A library module plus its `<Module>Tests` target (Fixtures/ copied as a test resource).
func module(
    _ name: String,
    dependencies: [Target.Dependency] = [],
    resources: [Resource]? = nil,
    testDependencies: [Target.Dependency] = []
) -> [Target] {
    [
        .target(
            name: name,
            dependencies: dependencies,
            resources: resources,
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "\(name)Tests",
            dependencies: [.target(name: name)] + testDependencies,
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
    ]
}

let package = Package(
    name: "FXVaultKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "FXVaultKit",
            targets: [
                "VaultData",
                "VaultCore",
                "SyncEngine",
                "SharingKit",
                "EnvTools",
                "GitHubKit",
                "VaultCrypto",
            ]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/jedisct1/swift-sodium.git", .upToNextMinor(from: "0.11.0")),
    ],
    targets: module("VaultCore")
        + module("VaultCrypto", dependencies: ["VaultCore", clibsodium])
        + module("VaultStore", dependencies: ["VaultCore", grdb], testDependencies: [grdb])
        + module("GitHubKit", dependencies: ["VaultCore"])
        + module("EnvTools", dependencies: ["VaultCore"])
        + module("SharingKit", dependencies: ["VaultCore"], resources: [.process("Resources")])
        + module("SyncEngine", dependencies: ["VaultCore", "VaultCrypto", "GitHubKit"])
        + module(
            "VaultData",
            dependencies: [
                "VaultCore",
                "VaultCrypto",
                "VaultStore",
                "GitHubKit",
                "EnvTools",
                "SharingKit",
                "SyncEngine",
            ]
        ),
    swiftLanguageModes: [.v6]
)
