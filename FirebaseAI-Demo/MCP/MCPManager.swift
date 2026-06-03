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
import Darwin
import MCP
import FirebaseAILogic

@MainActor
final class MCPManager {

    private let oauth = OAuthCoordinator()

    /// One tool a server exposes, with its (possibly namespaced) name and declaration.
    private struct ToolEntry {
        let exposed: String      // name presented to Gemini (namespaced on collision)
        let original: String     // name on the owning MCP server
        let declaration: FunctionDeclaration
    }

    /// Connected clients keyed by server config id.
    private var clients: [UUID: ManualMCPClient] = [:]
    /// Retained subprocesses for stdio servers, keyed by server config id.
    private var processes: [UUID: Process] = [:]
    /// Tools per server, so a single server can be added/removed independently.
    private var serverTools: [UUID: [ToolEntry]] = [:]
    /// Last config used per server, so we can transparently reconnect a dropped one.
    private var configsByID: [UUID: MCPServerConfig] = [:]

    /// Observable-ish status snapshot for the UI (read after connect calls).
    private(set) var statuses: [UUID: MCPServerStatus] = [:]

    // MARK: - Connection lifecycle

    /// Connect all enabled servers in `configs`, replacing any existing connections.
    func connectAll(_ configs: [MCPServerConfig]) async {
        await disconnectAll()
        for config in configs where config.enabled {
            await connect(config)
        }
    }

    /// Connect (or reconnect) a single server without disturbing the others.
    func connect(_ config: MCPServerConfig, timeout: Duration = .seconds(30)) async {
        await disconnect(config.id)   // clean slate if already connected
        configsByID[config.id] = config
        statuses[config.id] = MCPServerStatus(id: config.id, name: config.name, state: .connecting, toolCount: 0)

        let transport: any Transport
        var stderr: OutputCollector?
        var onTimeout: @Sendable () -> Void = {}

        do {
            switch config.transport {
            case .http(let url, let auth):
                let headers = try await authHeaders(for: auth, url: url)
                // HTTPClientTransport has no `headers:` param; inject auth via requestModifier.
                transport = HTTPClientTransport(
                    endpoint: url,
                    requestModifier: { request in
                        var req = request
                        for (key, value) in headers {
                            req.setValue(value, forHTTPHeaderField: key)
                        }
                        return req
                    }
                )

            case .stdio(let command, let arguments):
                let (process, t, err) = try StdioLauncher.launch(command: command, arguments: arguments)
                processes[config.id] = process
                transport = t
                stderr = err
                let pid = process.processIdentifier
                // On timeout, kill the child so a stuck handshake task can't leak.
                onTimeout = { kill(pid, SIGTERM) }
            }

            let client = ManualMCPClient(transport: transport)

            // Bounded handshake: start (connect + initialize) + listTools.
            let tools = try await withTimeout(timeout, onTimeout: onTimeout) {
                try await client.start()
                return try await client.listTools()
            }

            clients[config.id] = client
            register(tools: tools, for: config)
            statuses[config.id] = MCPServerStatus(id: config.id, name: config.name,
                                                  state: .connected, toolCount: tools.count)
        } catch {
            processes[config.id]?.terminate()
            processes[config.id] = nil

            let errText = stderr?.text ?? ""
            let detail = errText.isEmpty ? error.localizedDescription
                                         : "\(error.localizedDescription) — stderr: \(errText)"

            let needsAuth: Bool
            if case .http(_, .oauth) = config.transport { needsAuth = true } else { needsAuth = false }
            statuses[config.id] = MCPServerStatus(
                id: config.id, name: config.name,
                state: needsAuth ? .needsAuth : .failed(detail),
                toolCount: 0
            )
            print("⚠️ MCP connect failed for \(config.name): \(detail)")
        }
    }

    /// Races `op` against a timeout. On timeout, runs `onTimeout` (e.g. kill the
    /// child) and throws; the (possibly stuck) `op` task is abandoned. Needed
    /// because the SDK's `Client.connect` awaits `initialize` and won't fail on EOF.
    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        onTimeout: @escaping @Sendable () -> Void,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let once = OnceFlag()
        let seconds = Int(timeout.components.seconds)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let timeoutTask = Task {
                try? await Task.sleep(for: timeout)
                // Only act if the timeout actually wins; never kill a server that
                // already connected successfully.
                if once.claim() {
                    onTimeout()
                    cont.resume(throwing: MCPBridgeError.timedOut("Handshake didn't complete in \(seconds)s (server never answered initialize)."))
                }
            }
            Task {
                do {
                    let v = try await op()
                    if once.claim() { timeoutTask.cancel(); cont.resume(returning: v) }
                } catch {
                    if once.claim() { timeoutTask.cancel(); cont.resume(throwing: error) }
                }
            }
        }
    }

    /// Disconnect a single server: close its client, kill its subprocess, drop its tools.
    func disconnect(_ id: UUID) async {
        if let client = clients[id] { await client.stop() }
        clients[id] = nil
        if let process = processes[id], process.isRunning { process.terminate() }
        processes[id] = nil
        serverTools[id] = nil
        if var status = statuses[id] {
            status.state = .disconnected
            status.toolCount = 0
            statuses[id] = status
        }
    }

    func disconnectAll() async {
        for id in Array(clients.keys) { await disconnect(id) }
        // Also terminate any orphaned processes just in case.
        for (_, process) in processes where process.isRunning { process.terminate() }
        clients.removeAll()
        processes.removeAll()
        serverTools.removeAll()
    }

    // MARK: - Tool registration & declarations

    private func register(tools: [ManualMCPClient.DiscoveredTool], for config: MCPServerConfig) {
        var taken = allExposedNames(excluding: config.id)
        var entries: [ToolEntry] = []
        for tool in tools {
            // Namespace on collision with a tool name already used by another server.
            var exposedName = tool.name
            if taken.contains(exposedName) {
                exposedName = "\(sanitize(config.name))_\(tool.name)"
            }
            taken.insert(exposedName)

            let (props, optional) = SchemaConverter.functionParameters(tool.inputSchema)
            entries.append(ToolEntry(
                exposed: exposedName,
                original: tool.name,
                declaration: FunctionDeclaration(
                    name: exposedName,
                    description: tool.description,
                    parameters: props,
                    optionalParameters: optional
                )
            ))
        }
        serverTools[config.id] = entries
    }

    private func allExposedNames(excluding id: UUID?) -> Set<String> {
        var names = Set<String>()
        for (sid, entries) in serverTools where sid != id {
            for entry in entries { names.insert(entry.exposed) }
        }
        return names
    }

    func aggregatedFunctionDeclarations() -> [FunctionDeclaration] {
        serverTools.values.flatMap { $0.map(\.declaration) }
    }

    /// Returns the (serverID, original tool name) that owns an exposed tool name.
    private func route(_ exposedName: String) -> (serverID: UUID, original: String)? {
        for (sid, entries) in serverTools {
            if let entry = entries.first(where: { $0.exposed == exposedName }) {
                return (sid, entry.original)
            }
        }
        return nil
    }

    /// True if `name` is provided by some connected MCP server.
    func handles(_ name: String) -> Bool {
        route(name) != nil
    }

    // MARK: - Tool dispatch

    func callTool(name: String, args: JSONObject) async throws -> JSONObject {
        guard let (serverID, originalName) = route(name) else {
            throw MCPBridgeError.unknownTool(name)
        }
        let foundationArgs = args.mapValues { jsonValueToFoundation($0) }

        func invoke() async throws -> (text: String, isError: Bool) {
            guard let client = clients[serverID] else { throw MCPBridgeError.notConnected }
            return try await client.callTool(name: originalName, arguments: foundationArgs)
        }

        do {
            let result = try await invoke()
            return ["result": .string(result.text), "isError": .bool(result.isError)]
        } catch {
            // The subprocess may have exited (broken pipe). Reconnect once and retry,
            // re-resolving the tool name in case it got namespaced again.
            print("⚠️ MCP tool \(name) failed (\(error.localizedDescription)); reconnecting and retrying…")
            guard let config = configsByID[serverID] else { throw error }
            await connect(config)
            guard let (_, retryOriginal) = route(name), let client = clients[serverID] else { throw error }
            let result = try await client.callTool(name: retryOriginal, arguments: foundationArgs)
            return ["result": .string(result.text), "isError": .bool(result.isError)]
        }
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

    /// Firebase `JSONValue` → Foundation JSON value for JSONSerialization.
    private func jsonValueToFoundation(_ value: JSONValue) -> Any {
        switch value {
        case .null:          return NSNull()
        case .bool(let b):   return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a):  return a.map { jsonValueToFoundation($0) }
        case .object(let o): return o.mapValues { jsonValueToFoundation($0) }
        }
    }

    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
