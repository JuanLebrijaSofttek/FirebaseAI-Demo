//
//  MCPManager.swift
//  FirebaseAI-Demo
//
//  Owns multiple MCP server connections, aggregates their tools into Firebase
//  FunctionDeclarations, and routes tool calls to the owning server.
//
//  NOTE: The MCP SDK API (Client, HTTPClientTransport, listTools, callTool,
//  Tool, Value, Tool.Content) follows the published swift-sdk surface and may
//  need minor reconciliation against the exact installed version.
//

import Foundation
import MCP
import FirebaseAILogic

@MainActor
final class MCPManager {

    private let oauth = OAuthCoordinator()

    /// Connected clients keyed by server config id.
    private var clients: [UUID: Client] = [:]
    /// Retained subprocesses for stdio servers, keyed by server config id.
    private var processes: [UUID: Process] = [:]
    /// Exposed (possibly namespaced) tool name → server id.
    private var toolToServer: [String: UUID] = [:]
    /// Exposed tool name → original tool name on the server.
    private var exposedToOriginal: [String: String] = [:]
    /// Cached FunctionDeclarations for the current connection set.
    private var declarations: [FunctionDeclaration] = []

    /// Observable-ish status snapshot for the UI (read after connect calls).
    private(set) var statuses: [UUID: MCPServerStatus] = [:]

    // MARK: - Connection lifecycle

    /// Connect all enabled servers in `configs`, replacing any existing connections.
    func connectAll(_ configs: [MCPServerConfig]) async {
        await disconnectAll()
        for config in configs where config.enabled {
            await connect(config)
        }
        rebuildDeclarations()
    }

    func connect(_ config: MCPServerConfig) async {
        statuses[config.id] = MCPServerStatus(id: config.id, name: config.name, state: .connecting, toolCount: 0)
        do {
            let client = Client(name: "FirebaseAI-Demo", version: "1.0.0")

            switch config.transport {
            case .http(let url, let auth):
                let headers = try await authHeaders(for: auth, url: url)
                // HTTPClientTransport has no `headers:` param; inject auth via requestModifier.
                let transport = HTTPClientTransport(
                    endpoint: url,
                    requestModifier: { request in
                        var req = request
                        for (key, value) in headers {
                            req.setValue(value, forHTTPHeaderField: key)
                        }
                        return req
                    }
                )
                _ = try await client.connect(transport: transport)

            case .stdio(let command, let arguments):
                let (process, transport, _) = try StdioLauncher.launch(command: command, arguments: arguments)
                processes[config.id] = process
                _ = try await client.connect(transport: transport)
            }

            let (tools, _) = try await client.listTools()
            clients[config.id] = client
            register(tools: tools, for: config)

            statuses[config.id] = MCPServerStatus(id: config.id, name: config.name,
                                                  state: .connected, toolCount: tools.count)
        } catch {
            // Tear down a half-started stdio subprocess.
            processes[config.id]?.terminate()
            processes[config.id] = nil

            let needsAuth: Bool
            if case .http(_, .oauth) = config.transport { needsAuth = true } else { needsAuth = false }
            statuses[config.id] = MCPServerStatus(
                id: config.id, name: config.name,
                state: needsAuth ? .needsAuth : .failed(error.localizedDescription),
                toolCount: 0
            )
            print("⚠️ MCP connect failed for \(config.name): \(error)")
        }
    }

    func disconnectAll() async {
        for (_, client) in clients {
            await client.disconnect()
        }
        for (_, process) in processes where process.isRunning {
            process.terminate()
        }
        clients.removeAll()
        processes.removeAll()
        toolToServer.removeAll()
        exposedToOriginal.removeAll()
        declarations.removeAll()
    }

    // MARK: - Tool registration & declarations

    private func register(tools: [MCP.Tool], for config: MCPServerConfig) {
        for tool in tools {
            // Namespace on collision with an already-registered tool name.
            var exposedName = tool.name
            if toolToServer[exposedName] != nil {
                exposedName = "\(sanitize(config.name))_\(tool.name)"
            }
            toolToServer[exposedName] = config.id
            exposedToOriginal[exposedName] = tool.name

            let (props, optional) = SchemaConverter.functionParameters(tool.inputSchema)
            declarations.append(FunctionDeclaration(
                name: exposedName,
                description: tool.description ?? "",
                parameters: props,
                optionalParameters: optional
            ))
        }
    }

    private func rebuildDeclarations() {
        // Declarations are appended during register(); hook kept for future
        // de-duplication if needed.
    }

    func aggregatedFunctionDeclarations() -> [FunctionDeclaration] {
        declarations
    }

    /// True if `name` is provided by some connected MCP server.
    func handles(_ name: String) -> Bool {
        toolToServer[name] != nil
    }

    // MARK: - Tool dispatch

    func callTool(name: String, args: JSONObject) async throws -> JSONObject {
        guard let serverID = toolToServer[name], let client = clients[serverID] else {
            throw MCPBridgeError.unknownTool(name)
        }
        let originalName = exposedToOriginal[name] ?? name
        let mcpArgs = convertArgsToMCP(args)
        let result = try await client.callTool(name: originalName, arguments: mcpArgs)
        return flattenResult(result.content, isError: result.isError ?? false)
    }

    // MARK: - Auth

    private func authHeaders(for auth: MCPAuth, url: URL) async throws -> [String: String] {
        switch auth {
        case .none:
            return [:]
        case .bearer(let token):
            return ["Authorization": "Bearer \(token)"]
        case .oauth:
            let token = try await oauth.accessToken(for: url)
            return ["Authorization": "Bearer \(token)"]
        }
    }

    // MARK: - Value conversion

    private func convertArgsToMCP(_ obj: JSONObject) -> [String: MCP.Value] {
        obj.reduce(into: [:]) { acc, pair in
            acc[pair.key] = jsonValueToMCP(pair.value)
        }
    }

    private func jsonValueToMCP(_ value: JSONValue) -> MCP.Value {
        switch value {
        case .null:          return .null
        case .bool(let b):   return .bool(b)
        case .number(let n): return .double(n)
        case .string(let s): return .string(s)
        case .array(let a):  return .array(a.map { jsonValueToMCP($0) })
        case .object(let o): return .object(o.mapValues { jsonValueToMCP($0) })
        }
    }

    private func flattenResult(_ content: [MCP.Tool.Content], isError: Bool) -> JSONObject {
        let text = content.compactMap { block -> String? in
            if case .text(let t, _, _) = block { return t }
            return nil
        }.joined(separator: "\n")

        return [
            "result": .string(text.isEmpty ? "(no output)" : text),
            "isError": .bool(isError)
        ]
    }

    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
