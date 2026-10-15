// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DrawPort",
    platforms: [.iOS(.v18)],
    products: [.library(name: "DrawPort", targets: ["DrawPort"])],
    targets: [.target(name: "DrawPort")],
    swiftLanguageModes: [.v5]
)
