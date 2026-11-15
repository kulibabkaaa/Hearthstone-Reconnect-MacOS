// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "HSReconnect",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "ProxyCore", targets: ["ProxyCore"]),
    .library(name: "AppCore", targets: ["AppCore"]),
    .library(name: "MonoReader", targets: ["MonoReader"]),
  ],
  targets: [
    .target(
      name: "ProxyCore",
      path: "Shared/ProxyCore"
    ),
    .target(
      name: "AppCore",
      path: "Shared/AppCore"
    ),
    .target(
      name: "MonoReader",
      path: "Shared/MonoReader",
      exclude: ["NOTICE.md"]
    ),
    .testTarget(
      name: "ProxyCoreTests",
      dependencies: ["ProxyCore"],
      path: "Tests/ProxyCoreTests"
    ),
    .testTarget(
      name: "AppCoreTests",
      dependencies: ["AppCore"],
      path: "Tests/AppCoreTests"
    ),
    .testTarget(
      name: "MonoReaderTests",
      dependencies: ["MonoReader"],
      path: "Tests/MonoReaderTests"
    ),
  ]
)
