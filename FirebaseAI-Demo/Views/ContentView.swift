//
//  ContentView.swift
//  FirebaseAI-Demo
//
//  Created by Juan Ignacio Lebrija Muraira on 02/06/26.
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = ChatViewModel()
    @State private var inputText = ""
    @State private var showingMCPServers = false

    private let examples: [(label: String, icon: String, prompt: String)] = [
        ("URL Context",    "doc.text.magnifyingglass", "Summarize the content at https://swift.org/blog/ and list the 3 most recent posts."),
        ("Code Execution", "terminal",                 "Write and run Python code to compute the first 15 Fibonacci numbers and print them."),
        ("Google Search",  "magnifyingglass",          "What are the latest news about Swift 6 concurrency? Use Google Search to ground your answer.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let last = viewModel.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .frame(maxWidth: 850)

            Divider()

            HStack(spacing: 12) {
                HStack {
                    TextField("Message...", text: $inputText)
                        .textFieldStyle(.plain)
                    if !inputText.isEmpty {
                        Button { inputText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separatorColor)))

                if viewModel.isLoading {
                    Button {
                        viewModel.cancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                } else {
                    Button {
                        let text = inputText
                        inputText = ""
                        viewModel.send(text)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(inputText.isEmpty)
                }
            }
            .padding()
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                ForEach(examples, id: \.label) { example in
                    Button {
                        viewModel.send(example.prompt)
                    } label: {
                        Label(example.label, systemImage: example.icon)
                    }
                    .disabled(viewModel.isLoading)
                }
                Divider()
                Button {
                    showingMCPServers = true
                } label: {
                    Label("MCP Servers", systemImage: "server.rack")
                }
                Button(role: .destructive) {
                    viewModel.clearChat()
                } label: {
                    Label("Clear Chat", systemImage: "trash")
                }
                .disabled(viewModel.messages.isEmpty || viewModel.isLoading)
            }
        }
        .sheet(isPresented: $showingMCPServers) {
            MCPServersView(viewModel: viewModel)
        }
    }
}

#Preview {
    ContentView()
}
