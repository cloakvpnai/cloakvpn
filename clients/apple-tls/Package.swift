// swift-tools-version:5.9
import Foundation
import PackageDescription

let openssl = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path + "/Vendor/openssl-macos"

// LatticeTLS: Lattice VPN's CNSA 2.0 tunnel client for Apple platforms.
// TLS 1.3 is done by OpenSSL 3.5 (Vendor/openssl-macos, built by
// build-openssl.sh, Apache 2.0 license). This package only carries the
// tunnel framing around it.
let package = Package(
    name: "LatticeTLS",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "LatticeTLS", targets: ["LatticeTLS"])],
    targets: [
        .target(
            name: "CLatticeTLS",
            cSettings: [.unsafeFlags(["-I\(openssl)/include"])],
            linkerSettings: [.unsafeFlags(["-L\(openssl)/lib", "-lssl", "-lcrypto"])]
        ),
        .target(name: "LatticeTLS", dependencies: ["CLatticeTLS"]),
        .executableTarget(name: "tlsprobe", dependencies: ["LatticeTLS"]),
        .testTarget(name: "LatticeTLSTests", dependencies: ["LatticeTLS"]),
    ]
)
