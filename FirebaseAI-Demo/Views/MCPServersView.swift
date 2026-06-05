//
//  MCPServersView.swift
//  FirebaseAI-Demo
//
//  Add / remove MCP servers, trigger auth, and reflect connection status.
//

import SwiftUI

struct MCPServersView: View {
    let viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var servers: [MCPServerConfig] = MCPServerStore.loadOrSeed()
    @State private var showingAdd = false
    /// Per-server in-flight actions, so each row shows its own spinner.
    @State private var inProgress: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                if servers.isEmpty {
                    ContentUnavailableView(
                        "No MCP Servers",
                        systemImage: "server.rack",
                        description: Text("Add a remote MCP server (Figma, Google Docs, …) or a local http://localhost URL.")
                    )
                }
                ForEach(servers) { server in
                    row(for: server)
                }
                .onDelete { indexSet in
                    let removed = indexSet.map { servers[$0] }
                    servers.remove(atOffsets: indexSet)
                    MCPServerStore.save(servers)
                    for server in removed {
                        Task { await viewModel.disconnectServer(server.id) }
                    }
                }
            }
            .navigationTitle("MCP Servers")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAdd) {
                MCPServerEditor { newServer in
                    servers.append(newServer)
                    MCPServerStore.save(servers)
                    runAction(newServer.id) { await viewModel.connectServer(newServer) }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 360)
    }

    @ViewBuilder
    private func row(for server: MCPServerConfig) -> some View {
        let status = viewModel.mcpStatuses.first { $0.id == server.id }
        HStack(spacing: 10) {
            Circle()
                .fill(color(for: status?.state))
                .opacity(server.enabled ? 1 : 0.4)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.body)
                Text(subtitle(for: server.transport))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .opacity(server.enabled ? 1 : 0.5)

            Spacer()

            statusDetail(for: server, status: status)
            actionButton(for: server, status: status)
        }
        .padding(.vertical, 2)
    }

    /// Reflects the *connection* state (independent of enabled), with a muted "· off"
    /// suffix on the tool count when the server is disabled.
    @ViewBuilder
    private func statusDetail(for server: MCPServerConfig, status: MCPServerStatus?) -> some View {
        switch status?.state ?? .disconnected {
        case .connected:
            Text("\(status?.toolCount ?? 0) tools" + (server.enabled ? "" : " · off"))
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let msg):
            Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(1)
        case .needsAuth:
            Text("Needs sign-in").font(.caption2).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    /// The Enable/Disable toggle is always available; a Connect/Sign-in button appears
    /// only when the connection itself needs attention.
    @ViewBuilder
    private func actionButton(for server: MCPServerConfig, status: MCPServerStatus?) -> some View {
        HStack(spacing: 8) {
            if inProgress.contains(server.id) {
                ProgressView().controlSize(.small)
            } else {
                switch status?.state ?? .disconnected {
                case .connecting:
                    ProgressView().controlSize(.small)
                case .connected:
                    EmptyView()
                case .needsAuth:
                    Button("Sign in") { connectAction(server) }
                        .font(.caption).buttonStyle(.borderedProminent)
                default:
                    // Not connected (failed / disconnected) → retry.
                    Button("Connect") { connectAction(server) }
                        .font(.caption).buttonStyle(.borderedProminent)
                }
            }

            Button(server.enabled ? "Disable" : "Enable") { setEnabled(server, !server.enabled) }
                .font(.caption).buttonStyle(.bordered)
        }
    }

    /// Flip the enabled flag: persist it and rebuild the model's tool set. The server's
    /// connection (and subprocess) is left untouched.
    private func setEnabled(_ server: MCPServerConfig, _ enabled: Bool) {
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[idx].enabled = enabled
        MCPServerStore.save(servers)
        viewModel.setServerEnabled(server.id, enabled)
    }

    private func connectAction(_ server: MCPServerConfig) {
        runAction(server.id) { await viewModel.connectServer(server) }
    }

    /// Marks a server busy for the duration of `work`, so only its row spins.
    private func runAction(_ id: UUID, _ work: @escaping () async -> Void) {
        inProgress.insert(id)
        Task {
            await work()
            inProgress.remove(id)
        }
    }

    private func subtitle(for transport: MCPTransport) -> String {
        switch transport {
        case .http(let url, _):       return url.absoluteString
        case .stdio(let cmd, let args): return ([cmd] + args).joined(separator: " ")
        }
    }

    private func color(for state: MCPServerStatus.State?) -> Color {
        switch state {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .needsAuth:    return .orange
        case .failed:       return .red
        case .disconnected, .none: return .gray
        }
    }

}

// MARK: - Add/Edit editor

private struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: (MCPServerConfig) -> Void

    @State private var name = ""
    @State private var transportKind = TransportKind.http
    // HTTP
    @State private var urlString = ""
    @State private var authType = AuthType.none
    @State private var token = ""
    // Stdio
    @State private var command = ""
    @State private var argumentsText = ""

    private enum TransportKind: String, CaseIterable, Identifiable {
        case http = "Remote (HTTP)", stdio = "Local (Stdio)"
        var id: String { rawValue }
    }
    private enum AuthType: String, CaseIterable, Identifiable {
        case none = "None", bearer = "Bearer Token", oauth = "OAuth (browser)"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name (e.g. Figma)", text: $name)
                    Picker("Transport", selection: $transportKind) {
                        ForEach(TransportKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                }

                if transportKind == .http {
                    Section("Endpoint") {
                        TextField("URL (https://… or http://localhost:PORT)", text: $urlString)
                            .textContentType(.URL)
                            #if os(iOS)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            #endif
                    }
                    Section("Authentication") {
                        Picker("Type", selection: $authType) {
                            ForEach(AuthType.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if authType == .bearer {
                            SecureField("Token", text: $token)
                        }
                    }
                } else {
                    Section("Command") {
                        TextField("Command (e.g. /usr/bin/xcrun or npx)", text: $command)
                            #if os(iOS)
                            .autocapitalization(.none)
                            #endif
                        TextField("Arguments (one per line)", text: $argumentsText, axis: .vertical)
                            .lineLimit(2...6)
                            #if os(iOS)
                            .autocapitalization(.none)
                            #endif
                    }
                }
            }
            .navigationTitle("Add MCP Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch transportKind {
        case .http:
            return URL(string: urlString)?.scheme != nil && (authType != .bearer || !token.isEmpty)
        case .stdio:
            return !command.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func save() {
        let transport: MCPTransport
        switch transportKind {
        case .http:
            guard let url = URL(string: urlString) else { return }
            let auth: MCPAuth
            switch authType {
            case .none:   auth = .none
            case .bearer: auth = .bearer(token: token)
            case .oauth:  auth = .oauth
            }
            transport = .http(url: url, auth: auth)
        case .stdio:
            let args = argumentsText
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            transport = .stdio(command: command.trimmingCharacters(in: .whitespaces), arguments: args)
        }
        onSave(MCPServerConfig(name: name, transport: transport))
        dismiss()
    }
}
