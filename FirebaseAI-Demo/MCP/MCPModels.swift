//
//  MCPModels.swift
//  FirebaseAI-Demo
//
//  Configuration + error types for the MCP bridge.
//

import Foundation

/// How to authenticate against a remote (HTTP) MCP server.
enum MCPAuth: Codable, Equatable {
    case none
    case bearer(token: String)
    case oauth
}

/// Transport used to reach an MCP server.
enum MCPTransport: Codable, Equatable {
    /// Remote Streamable-HTTP server.
    case http(url: URL, auth: MCPAuth)
    /// Local subprocess speaking MCP over stdio (e.g. `xcrun mcpbridge`).
    case stdio(command: String, arguments: [String])
}

/// A user-configured MCP server.
struct MCPServerConfig: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var transport: MCPTransport
    var enabled: Bool = true
}

extension MCPServerConfig {
    /// Apple's Xcode MCP (Xcode 26.3+, Settings → Intelligence → MCP → Xcode Tools).
    static let xcodeTools = MCPServerConfig(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
        name: "Xcode Tools",
        transport: .stdio(command: "/usr/bin/xcrun", arguments: ["mcpbridge"])
    )

    /// XcodeBuildMCP (Sentry/Cameron Cooke), launched via npx.
    static let xcodeBuildMCP = MCPServerConfig(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!,
        name: "XcodeBuildMCP",
        transport: .stdio(command: "npx", arguments: ["-y", "xcodebuildmcp@latest", "mcp"])
    )

    static let builtIns: [MCPServerConfig] = [.xcodeTools, .xcodeBuildMCP]
}

enum MCPBridgeError: LocalizedError {
    case notConnected
    case unknownTool(String)
    case authRequired(URL)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConnected:        return "MCP client is not connected."
        case .unknownTool(let n):  return "No connected MCP server provides the tool \"\(n)\"."
        case .authRequired(let u): return "Authentication required for \(u.absoluteString)."
        case .invalidResponse:     return "The MCP server returned an unexpected response."
        }
    }
}

/// Live status of a configured server, surfaced to the UI.
struct MCPServerStatus: Identifiable {
    let id: UUID
    var name: String
    var state: State
    var toolCount: Int

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case needsAuth
        case failed(String)
    }
}

/// Lightweight persistence for the server list, seeded with the built-in servers.
enum MCPServerStore {
    private static let key = "mcp.servers.v2"

    static func load() -> [MCPServerConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let configs = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return []
        }
        return configs
    }

    /// Returns stored servers, seeding the built-ins on first run.
    static func loadOrSeed() -> [MCPServerConfig] {
        let stored = load()
        guard stored.isEmpty else { return stored }
        save(MCPServerConfig.builtIns)
        return MCPServerConfig.builtIns
    }

    static func save(_ configs: [MCPServerConfig]) {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
