//
//  MCPConnectionProbe.swift
//  FirebaseAI-Demo
//
//  A self-contained connection check for a stdio MCP server. Drives the MCP
//  handshake manually over the SDK's StdioTransport with step-by-step logging,
//  so we can see exactly where a stall happens (transport connect / send /
//  receive). Returns plain tool names so test targets can call it via
//  `@testable import` without importing MCP/System themselves.
//

import Foundation
import Darwin
import MCP

enum MCPConnectionProbe {

    enum ProbeError: LocalizedError {
        case timedOut(seconds: Int, diagnostics: String)
        case badResponse(String)
        var errorDescription: String? {
            switch self {
            case .timedOut(let s, let diag):
                return "MCP connection timed out after \(s)s.\n\(diag)"
            case .badResponse(let m):
                return "MCP probe got an unexpected response: \(m)"
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ p: Process) { self.process = p }
    }

    static func probe(command: String, arguments: [String], timeout: Duration = .seconds(60)) async throws -> [String] {
        let (process, transport, stderr) = try StdioLauncher.launch(command: command, arguments: arguments)
        let box = ProcessBox(process)
        let pid = process.processIdentifier
        let once = Once()
        let timeoutSeconds = Int(timeout.components.seconds)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String], Error>) in
            Task {
                _ = box.process  // retain subprocess for the connection's lifetime
                do {
                    let names = try await handshake(transport: transport, pid: pid)
                    if once.claim() { cont.resume(returning: names) }
                } catch {
                    print("🧪 Probe: error: \(error)")
                    let err = stderr.text
                    if !err.isEmpty { print("🧪 Probe: child stderr:\n\(err)") }
                    if once.claim() { cont.resume(throwing: error) }
                }
                kill(pid, SIGTERM)
            }

            Task {
                try? await Task.sleep(for: timeout)
                let running = box.process.isRunning
                let exit = running ? "still running" : "exited (status \(box.process.terminationStatus))"
                let diagnostics = """
                  command: \(command) \(arguments.joined(separator: " "))
                  pid: \(pid) — \(exit)
                  child stderr: \(stderr.text.isEmpty ? "(empty)" : "\n\(stderr.text)")
                """
                print("🧪 Probe: TIMEOUT after \(timeoutSeconds)s\n\(diagnostics)")
                kill(pid, SIGTERM)
                if once.claim() {
                    cont.resume(throwing: ProbeError.timedOut(seconds: timeoutSeconds, diagnostics: diagnostics))
                }
            }
        }
    }

    /// Manual MCP handshake: initialize → notifications/initialized → tools/list.
    private static func handshake(transport: StdioTransport, pid: Int32) async throws -> [String] {
        print("🧪 Probe: transport.connect()… (pid \(pid))")
        try await transport.connect()
        print("🧪 Probe: transport connected; starting receive stream")

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()

        // 1) initialize
        let initReq = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"FirebaseAI-Demo-Probe","version":"1.0"}}}
        """
        print("🧪 Probe: sending initialize (\(initReq.utf8.count) bytes)")
        try await transport.send(Data(initReq.utf8))

        let initResp = try await nextMessage(&iterator, label: "initialize response")
        print("🧪 Probe: initialize response: \(snippet(initResp))")

        // 2) initialized notification
        let initialized = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        try await transport.send(Data(initialized.utf8))
        print("🧪 Probe: sent notifications/initialized")

        // 3) tools/list
        let listReq = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        print("🧪 Probe: sending tools/list")
        try await transport.send(Data(listReq.utf8))

        // Read until we get the response for id 2.
        for _ in 0..<10 {
            let msg = try await nextMessage(&iterator, label: "tools/list response")
            guard let obj = try? JSONSerialization.jsonObject(with: msg) as? [String: Any] else { continue }
            if let id = obj["id"] as? Int, id == 2 {
                let result = obj["result"] as? [String: Any]
                let tools = result?["tools"] as? [[String: Any]] ?? []
                let names = tools.compactMap { $0["name"] as? String }
                print("🧪 Probe: tools/list returned \(names.count): \(names.joined(separator: ", "))")
                return names
            }
        }
        throw ProbeError.badResponse("no tools/list result for id 2")
    }

    private static func nextMessage(
        _ iterator: inout AsyncThrowingStream<Data, Error>.AsyncIterator,
        label: String
    ) async throws -> Data {
        guard let data = try await iterator.next() else {
            throw ProbeError.badResponse("stream ended while awaiting \(label)")
        }
        return data
    }

    private static func snippet(_ data: Data) -> String {
        let s = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        return s.count > 200 ? String(s.prefix(200)) + "…" : s
    }
}
