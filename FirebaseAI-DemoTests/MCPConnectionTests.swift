//
//  MCPConnectionTests.swift
//  FirebaseAI-DemoTests
//
//  Connection checks for the two local stdio MCP servers.
//
//  REQUIREMENTS to pass (these fail loudly if unmet, by design):
//   • App Sandbox DISABLED for the app target (subprocess spawning).
//   • Xcode 26.3+ with Settings → Intelligence → MCP → Xcode Tools enabled
//     (for `xcrun mcpbridge`).
//   • Node/npx installed (for XcodeBuildMCP).
//

import Testing
@testable import FirebaseAI_Demo

struct MCPConnectionTests {

    @Test func xcodeMCPConnects() async throws {
        let tools = try await MCPConnectionProbe.probe(
            command: "/usr/bin/xcrun",
            arguments: ["mcpbridge"],
            timeout: .seconds(30)
        )
        #expect(!tools.isEmpty, "Xcode MCP returned no tools — is it enabled in Xcode Settings → Intelligence → MCP → Xcode Tools?")
    }

    @Test func xcodeBuildMCPConnects() async throws {
        let npx = try #require(
            StdioLauncher.resolveExecutable("npx"),
            "npx not found — install Node.js."
        )
        // First run downloads xcodebuildmcp via npx, which can be slow.
        let tools = try await MCPConnectionProbe.probe(
            command: npx,
            arguments: ["-y", "xcodebuildmcp@latest", "mcp"],
            timeout: .seconds(180)
        )
        #expect(!tools.isEmpty, "XcodeBuildMCP returned no tools.")
    }
}
