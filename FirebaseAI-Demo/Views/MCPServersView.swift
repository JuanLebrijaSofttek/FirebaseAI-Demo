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

    @State private var servers: [MCPServerConfig] = MCPServerStore.load()
    @State private var showingAdd = false
    @State private var reconnecting = false

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
                    servers.remove(atOffsets: indexSet)
                    persistAndReconnect()
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
                ToolbarItem(placement: .automatic) {
                    Button {
                        persistAndReconnect()
                    } label: {
                        if reconnecting { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(reconnecting)
                }
            }
            .sheet(isPresented: $showingAdd) {
                MCPServerEditor { newServer in
                    servers.append(newServer)
                    persistAndReconnect()
                }
            }
        }
    }

    @ViewBuilder
    private func row(for server: MCPServerConfig) -> some View {
        let status = viewModel.mcpStatuses.first { $0.id == server.id }
        HStack(spacing: 10) {
            Circle()
                .fill(color(for: status?.state))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.body)
                Text(subtitle(for: server.transport))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let status {
                switch status.state {
                case .connected:
                    Text("\(status.toolCount) tools").font(.caption).foregroundStyle(.secondary)
                case .needsAuth:
                    Button("Sign in") { persistAndReconnect() }
                        .font(.caption).buttonStyle(.borderedProminent)
                case .connecting:
                    ProgressView().controlSize(.small)
                case .failed(let msg):
                    Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(1)
                case .disconnected:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 2)
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

    private func persistAndReconnect() {
        MCPServerStore.save(servers)
        reconnecting = true
        Task {
            await viewModel.connectMCPAndRebuild()
            reconnecting = false
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
