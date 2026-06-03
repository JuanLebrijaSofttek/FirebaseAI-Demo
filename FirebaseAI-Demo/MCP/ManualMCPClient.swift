//
//  ManualMCPClient.swift
//  FirebaseAI-Demo
//
//  A minimal MCP client driven directly over the SDK's `Transport`, using the
//  JSON-RPC handshake we verified works (initialize → notifications/initialized →
//  tools/list → tools/call). We use this instead of the SDK `Client` because
//  `Client.connect` does not complete the initialize handshake over our stdio
//  transport in-app (it never resumes the pending request), whereas this path does.
//

import Foundation
import MCP

actor ManualMCPClient {

    struct DiscoveredTool: Sendable {
        let name: String
        let description: String
        let inputSchema: MCP.Value?
    }

    private let transport: any Transport
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var readTask: Task<Void, Never>?

    init(transport: any Transport) {
        self.transport = transport
    }

    /// Connects the transport, starts the read loop, and performs the MCP handshake.
    func start() async throws {
        try await transport.connect()
        let stream = await transport.receive()
        readTask = Task { [weak self] in
            do {
                for try await data in stream {
                    await self?.handle(data)
                }
            } catch {
                await self?.failAll(error)
            }
        }
        try await initialize()
    }

    func stop() async {
        readTask?.cancel()
        readTask = nil
        await transport.disconnect()
        failAll(MCPBridgeError.notConnected)
    }

    // MARK: - High-level operations

    func listTools() async throws -> [DiscoveredTool] {
        let resp = try await request(method: "tools/list", params: nil)
        let result = resp["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let description = tool["description"] as? String ?? ""
            var schema: MCP.Value?
            if let input = tool["inputSchema"],
               let data = try? JSONSerialization.data(withJSONObject: input) {
                schema = try? JSONDecoder().decode(MCP.Value.self, from: data)
            }
            return DiscoveredTool(name: name, description: description, inputSchema: schema)
        }
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
        let resp = try await request(method: "tools/call", params: ["name": name, "arguments": arguments])
        let result = resp["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]] ?? []
        let text = content
            .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
        let isError = result?["isError"] as? Bool ?? false
        return (text.isEmpty ? "(no output)" : text, isError)
    }

    // MARK: - Handshake

    private func initialize() async throws {
        _ = try await request(method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "FirebaseAI-Demo", "version": "1.0"]
        ])
        try await notify(method: "notifications/initialized")
    }

    // MARK: - JSON-RPC plumbing

    private func request(method: String, params: [String: Any]?) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: message)

        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task {
                do {
                    try await transport.send(data)
                } catch {
                    if let waiting = pending.removeValue(forKey: id) {
                        waiting.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func notify(method: String) async throws {
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        let data = try JSONSerialization.data(withJSONObject: message)
        try await transport.send(data)
    }

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? Int,
              let cont = pending.removeValue(forKey: id) else {
            return  // notification or server→client request: ignored
        }
        if let err = obj["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? "unknown error"
            cont.resume(throwing: MCPBridgeError.timedOut("server error: \(msg)"))
        } else {
            cont.resume(returning: obj)
        }
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, cont) in waiting { cont.resume(throwing: error) }
    }
}
