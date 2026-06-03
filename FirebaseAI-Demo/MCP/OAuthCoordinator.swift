//
//  OAuthCoordinator.swift
//  FirebaseAI-Demo
//
//  Browser-based OAuth (Authorization Code + PKCE) for MCP servers that require it,
//  following the MCP authorization spec: protected-resource discovery →
//  authorization-server metadata → (optional) dynamic client registration →
//  ASWebAuthenticationSession → token exchange → Keychain storage.
//
//  NOTE: If the installed MCP SDK exposes its own auth/token provider hook on
//  HTTPClientTransport, prefer that and use this only as a fallback.
//

import Foundation
import AuthenticationServices
import CryptoKit

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Callback scheme must be registered in Info.plist under CFBundleURLTypes, e.g.
/// scheme "firebaseai-demo" → redirect URI "firebaseai-demo://oauth".
private let callbackScheme = "firebaseai-demo"
private let redirectURI = "firebaseai-demo://oauth"

@MainActor
final class OAuthCoordinator: NSObject {

    /// Returns a valid bearer access token for `resource`, performing the full browser
    /// flow if there's no cached/refreshable token.
    func accessToken(for resource: URL) async throws -> String {
        if let cached = TokenStore.token(for: resource), !cached.isExpired {
            return cached.accessToken
        }
        if let cached = TokenStore.token(for: resource),
           let refresh = cached.refreshToken,
           let meta = try? await discoverAuthServer(for: resource),
           let refreshed = try? await exchangeRefresh(refresh, meta: meta, resource: resource) {
            TokenStore.save(refreshed, for: resource)
            return refreshed.accessToken
        }
        let meta = try await discoverAuthServer(for: resource)
        let token = try await authorize(meta: meta, resource: resource)
        TokenStore.save(token, for: resource)
        return token.accessToken
    }

    // MARK: - Discovery

    private struct AuthServerMetadata: Decodable {
        let authorization_endpoint: URL
        let token_endpoint: URL
        let registration_endpoint: URL?
    }

    /// Resolve the authorization server for a protected MCP resource via the
    /// well-known endpoints. Falls back to deriving from the resource origin.
    private func discoverAuthServer(for resource: URL) async throws -> AuthServerMetadata {
        let origin = resource.originURL
        // Try protected-resource metadata first (may point at an external auth server).
        var authBase = origin
        if let prm = try? await fetchJSON(origin.appending(path: ".well-known/oauth-protected-resource")),
           case let .dictionary(d) = prm,
           case let .string(server)? = d["authorization_servers_first"] ?? d["authorization_server"],
           let serverURL = URL(string: server) {
            authBase = serverURL
        }

        let metaURL = authBase.appending(path: ".well-known/oauth-authorization-server")
        let data = try await fetchData(metaURL)
        return try JSONDecoder().decode(AuthServerMetadata.self, from: data)
    }

    // MARK: - Authorization Code + PKCE

    private func authorize(meta: AuthServerMetadata, resource: URL) async throws -> StoredToken {
        let clientID = try await clientID(for: meta, resource: resource)

        let verifier = Self.randomURLSafe(64)
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomURLSafe(32)

        var comps = URLComponents(url: meta.authorization_endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "resource", value: resource.absoluteString)
        ]
        let authURL = comps.url!

        let callback = try await presentWebAuth(url: authURL)
        guard let cbComps = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let code = cbComps.queryItems?.first(where: { $0.name == "code" })?.value,
              cbComps.queryItems?.first(where: { $0.name == "state" })?.value == state else {
            throw MCPBridgeError.invalidResponse
        }

        return try await exchangeCode(code, verifier: verifier, clientID: clientID, meta: meta, resource: resource)
    }

    private func exchangeCode(_ code: String, verifier: String, clientID: String,
                              meta: AuthServerMetadata, resource: URL) async throws -> StoredToken {
        let body = formBody([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
            "resource": resource.absoluteString
        ])
        return try await postToken(meta.token_endpoint, body: body)
    }

    private func exchangeRefresh(_ refresh: String, meta: AuthServerMetadata, resource: URL) async throws -> StoredToken {
        let body = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "resource": resource.absoluteString
        ])
        return try await postToken(meta.token_endpoint, body: body)
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
    }

    private func postToken(_ endpoint: URL, body: Data) async throws -> StoredToken {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MCPBridgeError.invalidResponse
        }
        let tr = try JSONDecoder().decode(TokenResponse.self, from: data)
        let expiry = tr.expires_in.map { Date().addingTimeInterval(TimeInterval($0) - 30) }
        return StoredToken(accessToken: tr.access_token, refreshToken: tr.refresh_token, expiresAt: expiry)
    }

    // MARK: - Dynamic client registration (optional)

    private func clientID(for meta: AuthServerMetadata, resource: URL) async throws -> String {
        if let existing = TokenStore.clientID(for: resource) { return existing }
        guard let regEndpoint = meta.registration_endpoint else {
            // No registration endpoint — assume a public/pre-provisioned client id.
            return "firebaseai-demo"
        }
        var req = URLRequest(url: regEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "FirebaseAI-Demo",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["client_id"] as? String else {
            throw MCPBridgeError.invalidResponse
        }
        TokenStore.saveClientID(id, for: resource)
        return id
    }

    // MARK: - ASWebAuthenticationSession

    private func presentWebAuth(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? MCPBridgeError.invalidResponse)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    // MARK: - PKCE helpers

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private func formBody(_ params: [String: String]) -> Data {
        var comps = URLComponents()
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps.percentEncodedQuery?.data(using: .utf8) ?? Data()
    }

    private func fetchData(_ url: URL) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MCPBridgeError.invalidResponse
        }
        return data
    }

    private enum JSONish { case dictionary([String: JSONish]); case string(String); case other }
    private func fetchJSON(_ url: URL) async throws -> JSONish {
        let data = try await fetchData(url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .other }
        return .dictionary(obj.mapValues { v in
            if let s = v as? String { return .string(s) }
            if let arr = v as? [String], let first = arr.first { return .string(first) }
            return .other
        })
    }
}

// MARK: - Presentation anchor

extension OAuthCoordinator: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(AppKit)
        return NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #elseif canImport(UIKit)
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return scene?.keyWindow ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}

// MARK: - Token storage (Keychain)

struct StoredToken: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }
}

private enum TokenStore {
    static func token(for resource: URL) -> StoredToken? {
        guard let data = Keychain.read(account: "token:\(resource.host ?? resource.absoluteString)") else { return nil }
        return try? JSONDecoder().decode(StoredToken.self, from: data)
    }
    static func save(_ token: StoredToken, for resource: URL) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        Keychain.write(data, account: "token:\(resource.host ?? resource.absoluteString)")
    }
    static func clientID(for resource: URL) -> String? {
        Keychain.read(account: "client:\(resource.host ?? resource.absoluteString)").flatMap { String(data: $0, encoding: .utf8) }
    }
    static func saveClientID(_ id: String, for resource: URL) {
        Keychain.write(Data(id.utf8), account: "client:\(resource.host ?? resource.absoluteString)")
    }
}

private enum Keychain {
    static func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func write(_ data: Data, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }
}

// MARK: - Small utilities

private extension URL {
    /// Scheme + host (+ port) only.
    var originURL: URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.port = port
        return comps.url ?? self
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
