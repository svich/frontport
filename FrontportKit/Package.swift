// swift-tools-version: 6.2
import PackageDescription

let modules = [
    "FrontportCatalog",
    "FrontportReleases",
    "FrontportROMs",
    "FrontportBuilder",
    "FrontportPackager",
    "FrontportLibrary",
    "FrontportLauncher",
    "FrontportArtwork",
]

let package = Package(
    name: "FrontportKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "FrontportCore", targets: ["FrontportCore"])]
        + modules.map { .library(name: $0, targets: [$0]) }
        + [.executable(name: "frontport-catalog", targets: ["frontport-catalog"])],
    targets: [
        .target(name: "FrontportCore"),
        .testTarget(name: "FrontportCoreTests", dependencies: ["FrontportCore"]),
        .executableTarget(name: "frontport-catalog", dependencies: ["FrontportCore", "FrontportCatalog"]),
    ]
        + modules.map {
            .target(
                name: $0, dependencies: ["FrontportCore"],
                resources: $0 == "FrontportBuilder" ? [.copy("Profiles")] : nil)
        }
        // The Library's tests also re-sign through the real Packager, which polices links the fake doesn't.
        + modules.map {
            .testTarget(
                name: "\($0)Tests",
                dependencies: [.target(name: $0), "FrontportCore"] + ($0 == "FrontportLibrary" ? ["FrontportPackager", "FrontportROMs"] : []))
        }
        // Every real module composed over the bundled Catalog; opt-in, as it downloads and launches real Ports.
        + [.testTarget(name: "FrontportIntegrationTests", dependencies: ["FrontportCore"] + modules.map { .target(name: $0) })]
)
