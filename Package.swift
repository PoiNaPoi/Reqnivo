// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Reqnivo",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Reqnivo", targets: ["Reqnivo"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Reqnivo",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("Resources/bridge.py"), .copy("Resources/install-certificate.dex"), .copy("Resources/Reqnivo.icns")]
        ),
        .testTarget(name: "ReqnivoTests", dependencies: ["Reqnivo"])
    ]
)
