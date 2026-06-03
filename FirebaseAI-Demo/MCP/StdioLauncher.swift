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

/// One-shot claim guard for racing tasks (e.g. a timeout vs a worker).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

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
        var dirs: [String] = []
        // Prefer the compatible Node bin dir so `npx`/`node` come from it (e.g. nvm 24,
        // not Homebrew 25 which breaks firebase-tools).
        if let nodeDir = preferredNodeBinDir() { dirs.append(nodeDir) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
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
    /// directories and a Node bin dir, so `npx`'s `#!/usr/bin/env node` shebang can
    /// resolve (the app/test process inherits only the minimal launchd PATH otherwise).
    ///
    /// Prefers an nvm-installed LTS Node (major 24/22/20) over Homebrew's, because a
    /// too-new Node (e.g. 25) breaks some CLIs like `firebase-tools`.
    private static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var dirs: [String] = []
        if let nodeDir = preferredNodeBinDir() { dirs.append(nodeDir) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existing = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        let merged = (dirs + existing).filter { seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    /// The bin directory of the most suitable Node: the highest nvm-installed version
    /// with a firebase-tools-compatible major (24/22/20), else wherever `node` resolves.
    private static func preferredNodeBinDir() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvmDir = "\(home)/.nvm/versions/node"
        let compatibleMajors: Set<Int> = [24, 22, 20]

        func sortKey(_ parts: [Int]) -> Int {
            let major = parts.count > 0 ? parts[0] : 0
            let minor = parts.count > 1 ? parts[1] : 0
            let patch = parts.count > 2 ? parts[2] : 0
            return major * 1_000_000 + minor * 1_000 + patch
        }

        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            let best = entries.compactMap { name -> (key: Int, path: String)? in
                let v = name.hasPrefix("v") ? String(name.dropFirst()) : name
                let parts = v.split(separator: ".").compactMap { Int($0) }
                guard let major = parts.first, compatibleMajors.contains(major) else { return nil }
                let bin = "\(nvmDir)/\(name)/bin"
                return FileManager.default.isExecutableFile(atPath: "\(bin)/node") ? (sortKey(parts), bin) : nil
            }.max { $0.key < $1.key }
            if let best { return best.path }
        }

        // Fallback: scan common dirs directly (no resolveExecutable → avoids recursion).
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            if FileManager.default.isExecutableFile(atPath: "\(dir)/node") { return dir }
        }
        return nil
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

        process.terminationHandler = { p in
            let reason = p.terminationReason == .uncaughtSignal ? "signal" : "exit"
            print("🧪 StdioLauncher: child pid \(p.processIdentifier) ENDED (\(reason) status \(p.terminationStatus))")
            // On an abnormal exit (not our SIGTERM=15), surface the captured stderr.
            if p.terminationStatus != 0 && p.terminationStatus != 15 {
                let err = stderr.text
                if !err.isEmpty { print("🧪 StdioLauncher: pid \(p.processIdentifier) stderr:\n\(err)") }
            }
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
