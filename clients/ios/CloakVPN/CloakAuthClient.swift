// SPDX-License-Identifier: MIT
//
// Cloak VPN — Auth client.
//
// Responsible for getting (and caching) a JWT that authorizes
// provisioning calls against cloak-api-server. Two-step flow:
//
//   1. Cache check: if loadJWT() returns a token still ≥ JWT_REFRESH_BUFFER
//      seconds from expiry, use it as-is.
//   2. Otherwise: POST /api/v1/auth/exchange with the install UUID +
//      bootstrap key. Server returns a fresh JWT (24h lifetime),
//      which we persist and return.
//
// The JWT is shared across regions — the server-side JWT_SECRET is the
// same on every region — so we only need to bootstrap against one
// region (we use the user's currently-selected region for locality).
//
// Phase 2 (when StoreKit IAP ships):
//   - Drop the bootstrap-key path
//   - Send Transaction.currentEntitlements JWS instead of install_uuid
//   - Server validates the JWS with Apple's public key
//   - JWT subject becomes originalTransactionID instead of "install:UUID"
//
// The iOS calling code doesn't change — it still calls fetchAuthToken()
// and gets back a JWT to use as Authorization: Bearer.

import Foundation

enum CloakAuthError: LocalizedError {
    case noServerURL
    case bootstrapFailed(httpCode: Int, message: String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .noServerURL:
            return "auth: no region selected (need a serverURL to bootstrap against)"
        case .bootstrapFailed(let code, let message):
            return "auth: bootstrap HTTP \(code): \(message.prefix(200))"
        case .malformedResponse(let detail):
            return "auth: server response malformed: \(detail)"
        }
    }
}

enum CloakAuthClient {

    /// Refresh threshold — re-fetch a JWT this many seconds before its
    /// stated expiry. 1 hour buffer means a 24h JWT effectively gets
    /// refreshed every 23h, with no risk of using a token that expires
    /// mid-request. Picked to be much larger than typical clock skew.
    static let refreshBufferSeconds: Int = 60 * 60

    /// Get a usable JWT, refreshing from the server if the cached one is
    /// missing or close to expiry. `regionServerBase` is the HTTPS base
    /// URL to bootstrap against (e.g. "https://cloak-de1.cloakvpn.ai").
    static func fetchAuthToken(
        regionServerBase: String
    ) async throws -> String {
        if let cached = AppGroupKeyStore.loadJWT() {
            let now = Int(Date().timeIntervalSince1970)
            if cached.expUnix - now > refreshBufferSeconds {
                return cached.jwt
            }
        }
        // Cache miss / expiring soon — bootstrap a fresh one.
        let installUUID = AppGroupKeyStore.loadOrCreateInstallUUID()
        return try await bootstrapJWT(
            regionServerBase: regionServerBase,
            installUUID: installUUID
        )
    }

    /// POST /api/v1/auth/exchange to get a fresh JWT. Persists it on
    /// success and returns the token string.
    private static func bootstrapJWT(
        regionServerBase: String,
        installUUID: String
    ) async throws -> String {
        var base = regionServerBase.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/api/v1/auth/exchange") else {
            throw CloakAuthError.noServerURL
        }

        let body = try JSONSerialization.data(withJSONObject: [
            "install_uuid": installUUID,
        ])

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(CloakRegion.bootstrapKey, forHTTPHeaderField: "X-Cloak-Bootstrap-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 10

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw CloakAuthError.malformedResponse("non-HTTP response")
        }
        if http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "<binary>"
            throw CloakAuthError.bootstrapFailed(httpCode: http.statusCode, message: msg)
        }

        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let jwt = obj["jwt"] as? String,
              let exp = obj["exp"] as? Int
        else {
            throw CloakAuthError.malformedResponse("expected {jwt, exp}")
        }

        try AppGroupKeyStore.saveJWT(jwt, expUnix: exp)
        return jwt
    }

    /// Force a re-fetch on next call (drops the cached JWT).
    static func invalidateCache() {
        AppGroupKeyStore.clearJWT()
    }
}
