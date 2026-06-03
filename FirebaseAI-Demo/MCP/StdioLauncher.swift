//
//  StdioLauncher.swift
//  FirebaseAI-Demo
//
//  Spawns a local MCP server subprocess and wires its stdin/stdout into the
//  swift-sdk `StdioTransport`.
//
//  NOTE: The SDK's StdioTransport does NOT spawn processes — it only reads/writes
//  file descriptors (defaulting to this process's own stdio). We launch the child
//  with Foundation.Process + Pipes and hand the pipe FDs to the transport.
//
//  Requires App Sandbox to be DISABLED for the app target — sandboxed macOS apps
//  cannot spawn arbitrary subprocesses.
//

import Foundation
import MCP
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

/// Thread-safe accumulator for a child process's stderr (or any stream).
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum StdioLauncher {

    enum LaunchError: LocalizedError {
        case executableNotFound(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .executableNotFound(let name):
                return "Could not find executable \"\(name)\" in PATH or common locations."
            case .launchFailed(let msg):
                return "Failed to launch MCP subprocess: \(msg)"
            }
        }
    }

    /// Resolves an executable name to an absolute path. Absolute/relative paths
    /// containing "/" are returned as-is; bare names are searched in common Node
    /// locations and then `$PATH`.
    static func resolveExecutable(_ name: String) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Builds the child environment with a PATH that includes common tool
    /// directories and the directory containing `node`, so `npx`'s
    /// `#!/usr/bin/env node` shebang can resolve (the app/test process inherits
    /// only the minimal launchd PATH otherwise).
    private static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        if let node = resolveExecutable("node") {
            dirs.insert((node as NSString).deletingLastPathComponent, at: 0)
        }
        let existing = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        let merged = (dirs + existing).filter { seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    /// Launches `command arguments…` and returns the running process plus a
    /// `StdioTransport` bound to its stdio. Retain the returned `Process` for the
    /// lifetime of the connection (it keeps the pipe file descriptors open).
    static func launch(command: String, arguments: [String]) throws -> (process: Process, transport: StdioTransport, stderr: OutputCollector) {
        guard let executable = resolveExecutable(command) else {
            throw LaunchError.executableNotFound(command)
        }

        let inPipe = Pipe()    // we WRITE → child stdin
        let outPipe = Pipe()   // we READ  ← child stdout
        let errPipe = Pipe()   // capture child stderr (and keep it drained)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.environment = augmentedEnvironment()

        // Capture + drain stderr so the child can't block on a full pipe.
        let stderr = OutputCollector()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stderr.append(chunk) }
        }

        print("🧪 StdioLauncher: launching \(executable) \(arguments.joined(separator: " "))")
        do {
            try process.run()
        } catch {
            throw LaunchError.launchFailed(error.localizedDescription)
        }
        print("🧪 StdioLauncher: spawned pid \(process.processIdentifier)")

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: outPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: inPipe.fileHandleForWriting.fileDescriptor)
        )
        return (process, transport, stderr)
    }
}
