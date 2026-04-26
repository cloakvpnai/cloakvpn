import Foundation

/// Errors thrown by config parsing and tunnel lifecycle.
///
/// Lives in ConfigParser.swift (not TunnelManager.swift) so it can be
/// shared between the CloakVPN app target AND the CloakTunnel
/// NetworkExtension target — both compile ConfigParser.swift, but only
/// the app target compiles TunnelManager.swift (which is @MainActor +
/// SwiftUI and cannot run inside the extension).
enum TunnelError: Error, LocalizedError {
    case noConfig
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .noConfig: return "No VPN configuration imported yet."
        case .parse(let s): return "Parse error: \(s)"
        }
    }
}

/// Parsed representation of the config block produced by the server's
/// `setup.sh` / `add-peer.sh`. Intentionally flat — serialized into the
/// NETunnelProviderProtocol.providerConfiguration dictionary.
struct CloakConfig: Codable, Equatable {
    // WireGuard
    var wgPrivateKey: String
    var addressV4: String
    var addressV6: String
    var dns: [String]
    var peerPublicKey: String
    var endpoint: String
    var allowedIPs: [String]
    var persistentKeepalive: Int

    // Rosenpass PQC
    var pqEnabled: Bool
    var serverRPPublicKeyB64: String
    var rpEndpoint: String
    var clientRPSecretKeyB64: String
    var clientRPPublicKeyB64: String
    var pskRotationSeconds: Int

    /// Subset of fields suitable for `NETunnelProviderProtocol.providerConfiguration`.
    ///
    /// Deliberately EXCLUDES the three Rosenpass key blobs
    /// (`serverRPPublicKeyB64`, `clientRPSecretKeyB64`, `clientRPPublicKeyB64`).
    /// Those are ~700 KB each (Classic McEliece-460896 public keys, base64),
    /// totaling ~1.4 MB — well past what iOS will reliably persist in
    /// `providerConfiguration`. They live in the App Group container
    /// instead (see `AppGroupKeyStore`) and are loaded at connect time by
    /// the main app. The NE never needs them — Rosenpass runs in the main
    /// app only and pushes derived 32-byte PSKs to the NE via
    /// `sendProviderMessage`.
    var asDictionary: [String: Any] {
        [
            "wgPrivateKey": wgPrivateKey,
            "addressV4": addressV4, "addressV6": addressV6,
            "dns": dns,
            "peerPublicKey": peerPublicKey,
            "endpoint": endpoint,
            "allowedIPs": allowedIPs,
            "persistentKeepalive": persistentKeepalive,
            "pqEnabled": pqEnabled,
            "rpEndpoint": rpEndpoint,
            "pskRotationSeconds": pskRotationSeconds
        ]
    }

    init(dict: [String: Any]) throws {
        func req<T>(_ k: String) throws -> T {
            guard let v = dict[k] as? T else { throw TunnelError.parse("missing \(k)") }
            return v
        }
        wgPrivateKey         = try req("wgPrivateKey")
        addressV4            = try req("addressV4")
        addressV6            = try req("addressV6")
        dns                  = try req("dns")
        peerPublicKey        = try req("peerPublicKey")
        endpoint             = try req("endpoint")
        allowedIPs           = try req("allowedIPs")
        persistentKeepalive  = try req("persistentKeepalive")
        pqEnabled            = try req("pqEnabled")
        rpEndpoint           = try req("rpEndpoint")
        pskRotationSeconds   = try req("pskRotationSeconds")

        // The three Rosenpass key blobs live in the App Group container,
        // not in providerConfiguration (size — see `asDictionary`). When
        // this initializer runs from a freshly-loaded providerConfiguration
        // (either main app or NE), the keys are simply absent here; the
        // main app reloads them from `AppGroupKeyStore` at connect time,
        // and the NE never needs them. Tolerating absence keeps both
        // paths working without branching at the call site.
        serverRPPublicKeyB64 = (dict["serverRPPublicKeyB64"] as? String) ?? ""
        clientRPSecretKeyB64 = (dict["clientRPSecretKeyB64"] as? String) ?? ""
        clientRPPublicKeyB64 = (dict["clientRPPublicKeyB64"] as? String) ?? ""
    }

    init(wgPrivateKey: String, addressV4: String, addressV6: String, dns: [String],
         peerPublicKey: String, endpoint: String, allowedIPs: [String],
         persistentKeepalive: Int, pqEnabled: Bool,
         serverRPPublicKeyB64: String, rpEndpoint: String,
         clientRPSecretKeyB64: String, clientRPPublicKeyB64: String,
         pskRotationSeconds: Int) {
        self.wgPrivateKey = wgPrivateKey
        self.addressV4 = addressV4
        self.addressV6 = addressV6
        self.dns = dns
        self.peerPublicKey = peerPublicKey
        self.endpoint = endpoint
        self.allowedIPs = allowedIPs
        self.persistentKeepalive = persistentKeepalive
        self.pqEnabled = pqEnabled
        self.serverRPPublicKeyB64 = serverRPPublicKeyB64
        self.rpEndpoint = rpEndpoint
        self.clientRPSecretKeyB64 = clientRPSecretKeyB64
        self.clientRPPublicKeyB64 = clientRPPublicKeyB64
        self.pskRotationSeconds = pskRotationSeconds
    }
}

/// Minimal parser for the INI-style blocks emitted by server scripts.
/// Not a full INI grammar — tailored to the format we emit.
enum ConfigParser {
    static func parse(_ text: String) throws -> CloakConfig {
        var sections: [String: [String: String]] = [:]
        var current: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast())
                sections[current!] = [:]
                continue
            }
            guard let sec = current,
                  let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            sections[sec, default: [:]][k] = v
        }

        func v(_ section: String, _ key: String) throws -> String {
            guard let s = sections[section], let val = s[key] else {
                throw TunnelError.parse("[\(section)] \(key) missing")
            }
            return val
        }
        func list(_ section: String, _ key: String) throws -> [String] {
            try v(section, key).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        let wg = "wireguard"
        let peer = "wireguard.peer"
        let rp = "rosenpass"

        return CloakConfig(
            wgPrivateKey: try v(wg, "private_key"),
            addressV4: try v(wg, "address_v4"),
            addressV6: try v(wg, "address_v6"),
            dns: try list(wg, "dns"),
            peerPublicKey: try v(peer, "public_key"),
            endpoint: try v(peer, "endpoint"),
            allowedIPs: try list(peer, "allowed_ips"),
            persistentKeepalive: Int(try v(peer, "persistent_keepalive")) ?? 25,
            pqEnabled: sections[rp] != nil,
            serverRPPublicKeyB64: (try? v(rp, "server_public_key_b64")) ?? "",
            rpEndpoint: (try? v(rp, "server_endpoint")) ?? "",
            clientRPSecretKeyB64: (try? v(rp, "client_secret_key_b64")) ?? "",
            clientRPPublicKeyB64: (try? v(rp, "client_public_key_b64")) ?? "",
            pskRotationSeconds: Int((try? v(rp, "psk_rotation_seconds")) ?? "120") ?? 120
        )
    }
}
