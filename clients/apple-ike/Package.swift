// swift-tools-version: 6.0
import PackageDescription

// LatticeIKE: a single-profile IKEv2 initiator for the Lattice VPN Apple apps.
// It speaks only the CNSA 2.0 IPsec profile (AES-256-GCM, PRF-HMAC-SHA-384,
// ECP-384 + ML-KEM-1024, ML-DSA-87 certificates) and refuses everything else.
let package = Package(
    name: "LatticeIKE",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "LatticeIKE", targets: ["LatticeIKE"])],
    targets: [
        .target(name: "LatticeIKE", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "ikeprobe", dependencies: ["LatticeIKE"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
