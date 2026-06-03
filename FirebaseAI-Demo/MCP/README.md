# MCP Bridge — Reusable Module Guide

A self-contained bridge that connects an app to **MCP (Model Context Protocol)** servers
— remote (HTTP/SSE, optional OAuth) and local (stdio subprocess) — and exposes their
tools to an LLM via function calling. Built on the official Swift SDK
[`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk).

This folder is designed to be dropped into another project. Below is what it contains,
what it depends on, the **required project settings**, and how to integrate.

---

## What's in this folder

| File | Responsibility | Firebase dep? |
|---|---|---|
| `MCPModels.swift` | `MCPServerConfig`, `MCPTransport` (`.http`/`.stdio`), `MCPAuth`, `MCPServerStatus`, `MCPServerStore` (UserDefaults), built-in servers | **No** |
| `StdioLauncher.swift` | Spawns a local subprocess (`Process` + pipes) and wires its stdio into the SDK `StdioTransport`. Also `OutputCollector`, `OnceFlag` utilities | **No** |
| `ManualMCPClient.swift` | Minimal MCP client over the SDK `Transport` (initialize → tools/list → tools/call). Used instead of the SDK `Client` (see "Why ManualMCPClient") | **No** |
| `OAuthCoordinator.swift` | Browser OAuth (PKCE) via `ASWebAuthenticationSession` + Keychain, for remote servers needing auth | **No** |
| `MCPConnectionProbe.swift` | One-shot connect/list-tools check, returns plain `[String]`. Handy for unit tests | **No** |
| `SchemaConverter.swift` | Converts MCP JSON-Schema → **Firebase `Schema`** | **Yes** |
| `MCPManager.swift` | Owns all servers; connect/disconnect/route/call; produces **Firebase `FunctionDeclaration`s**; auto-reconnect-and-retry | **Yes** |

> Only `SchemaConverter.swift` and `MCPManager.swift` touch Firebase. Everything else is
> LLM-agnostic. To use a different LLM SDK, you only adapt those two (see "Decoupling").

The UI (`Views/MCPServersView.swift`) and the view-model wiring
(`ViewModel/ChatViewModel.swift`) live **outside** this folder — they're examples, not
part of the bridge.

---

## Dependencies

1. **Swift MCP SDK** (required): add the package
   `https://github.com/modelcontextprotocol/swift-sdk.git` (≥ 0.12.0), link product **`MCP`**.
2. **Firebase AI Logic** (only if you keep `SchemaConverter`/`MCPManager` as-is): product `FirebaseAILogic`.
3. System frameworks (auto-linked on import): `AuthenticationServices`, `CryptoKit`, `System`, `AppKit`/`UIKit`, `Darwin`.

Platform: macOS 13+ / iOS 16+ (uses `Duration`, `appending(path:)`, `ASWebAuthenticationSession`).
Stdio servers are **macOS-only** in practice (subprocess spawning).

---

## REQUIRED project setup (easy to miss)

These are not code in this folder — set them in the host app or they'll fail at runtime:

1. **Disable App Sandbox** (for stdio/local servers only):
   target → Signing & Capabilities → remove **App Sandbox**, or set `ENABLE_APP_SANDBOX = NO`.
   Sandboxed apps cannot spawn `xcrun`/`npx`; `xcrun` errors with *"cannot be used within an App Sandbox."*
   *(Remote HTTP servers work under the sandbox — only stdio needs this.)*

2. **Ignore SIGPIPE** at app startup — add to your `App.init()`:
   ```swift
   import Darwin
   signal(SIGPIPE, SIG_IGN)
   ```
   Without this, writing to a subprocess whose pipe closed raises SIGPIPE (signal 13) and
   **kills the app** instead of throwing a catchable error.

3. **OAuth callback scheme** (only if using `.oauth` servers): register a URL scheme in
   `Info.plist` (`CFBundleURLTypes`). Defaults in `OAuthCoordinator.swift`:
   scheme `firebaseai-demo`, redirect `firebaseai-demo://oauth`. Change both to your scheme.

---

## Quick start

```swift
let manager = MCPManager()                       // @MainActor

// 1. Connect (seed built-ins or pass your own configs)
await manager.connectAll(MCPServerStore.loadOrSeed())
// or a single server:
await manager.connect(MCPServerConfig(name: "Figma",
    transport: .http(url: URL(string: "https://mcp.figma.com/mcp")!, auth: .oauth)))

// 2. Build your LLM tool list from discovered MCP tools
let decls = manager.aggregatedFunctionDeclarations()   // [FunctionDeclaration]
// merge `decls` into your GenerativeModel's tools

// 3. When the model emits a function call your local handlers don't know:
if manager.handles(call.name) {
    let responseJSON = try await manager.callTool(name: call.name, args: call.args)
    // wrap responseJSON in a FunctionResponsePart and send back to the model
}

// 4. Per-server control / teardown
await manager.disconnect(serverID)   // removes just its tools
await manager.disconnectAll()        // on app teardown (kills subprocesses)
```

Statuses for UI: `manager.statuses` (`[UUID: MCPServerStatus]`).
Built-ins: `MCPServerConfig.xcodeTools`, `.xcodeBuildMCP`, `.builtIns`.

### Custom servers
```swift
// Remote, no auth
MCPServerConfig(name: "Docs", transport: .http(url: url, auth: .none))
// Remote, static token
MCPServerConfig(name: "Internal", transport: .http(url: url, auth: .bearer(token: "…")))
// Local stdio
MCPServerConfig(name: "MyTool", transport: .stdio(command: "npx", arguments: ["-y", "my-mcp"]))
```

---

## Why `ManualMCPClient` (not the SDK `Client`)

The SDK's `Client.connect` awaits the `initialize` response and, in this stdio setup, did
not reliably resume that pending request (it also never fails it on EOF). `ManualMCPClient`
drives the same JSON-RPC handshake directly over the SDK `Transport` and is what we verified
working end-to-end. `MCPManager.connect` wraps it in a timeout that kills a stuck child, and
`callTool` reconnects-and-retries once if the subprocess dropped (broken pipe).

---

## Decoupling from Firebase (to use another LLM SDK)

Replace the two coupled pieces:

- **`SchemaConverter.swift`** — currently returns Firebase `Schema`. Change `convertValue`
  / `functionParameters` to emit your SDK's schema type (it already parses MCP `Value`
  JSON-Schema; only the output type changes).
- **`MCPManager.swift`** — three touch points:
  - `register(...)` builds `FunctionDeclaration` → build your SDK's tool-declaration type.
  - `aggregatedFunctionDeclarations() -> [FunctionDeclaration]` → return your type.
  - `callTool(args: JSONObject) -> JSONObject` uses Firebase's `JSONObject`/`JSONValue`.
    Swap for your arg/return type, or change to `[String: Any]` (see `jsonValueToFoundation`,
    which already converts to Foundation JSON for the wire).

Everything else (`MCPModels`, `StdioLauncher`, `ManualMCPClient`, `OAuthCoordinator`,
`MCPConnectionProbe`) is reusable unchanged.

---

## Notes & limitations

- **Tool-name collisions** across servers are auto-namespaced (`ServerName_tool`); routing
  maps the exposed name back to the owning server + original name.
- **MCP resources/prompts** are not consumed — only tools.
- **OAuth**: hand-rolled PKCE flow; if your SDK version exposes an `authorizer` on
  `HTTPClientTransport`, you can prefer that.
- **`MCPServerStore`** persists to `UserDefaults` under key `mcp.servers.v2`.
- The verbose `🧪` `print`s in `StdioLauncher`/`MCPConnectionProbe` are debug aids — gate or
  remove for production.
