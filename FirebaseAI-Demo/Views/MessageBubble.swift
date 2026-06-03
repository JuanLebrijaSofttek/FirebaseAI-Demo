//
//  MessageBubble.swift
//  FirebaseAI-Demo
//
//  Created by Juan Ignacio Lebrija Muraira on 02/06/26.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

private func copyToClipboard(_ string: String) {
    #if canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    #elseif canImport(UIKit)
    UIPasteboard.general.string = string
    #endif
}

struct MessageBubble: View {
    let message: Message
    @State private var isExpanded = false
    @State private var expandedItems: Set<String> = []
    @State private var copied = false
    @State private var copiedCodeBlocks: Set<String> = []

    var body: some View {
        switch message.role {
        case .function:
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor(message.functionStatus))
                                .frame(width: 8, height: 8)
                            Image(systemName: "function")
                                .font(.caption)
                            Text(message.text)
                                .font(.caption)
                            Spacer()
                            if message.functionArgs != nil {
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    if isExpanded {
                        Divider()
                        if let args = message.functionArgs {
                            Text("Parameters")
                                .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                            Text(args)
                                .font(.caption2).monospaced()
                        }
                        if let result = message.functionResult {
                            Text("Result")
                                .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                                .padding(.top, 2)
                            Text(result)
                                .font(.caption2).monospaced()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemIndigo).opacity(0.12))
                .foregroundStyle(Color(.systemIndigo))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                Spacer()
            }

        case .user:
            HStack {
                Spacer()
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .textSelection(.enabled)
                    .frame(maxWidth: 700, alignment: .trailing)
            }

        case .model:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(message.contentItems) { item in
                            itemView(for: item)
                        }
                        if message.isStreaming {
                            TypingIndicator()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.quaternary)
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    if !message.isStreaming && !message.contentItems.isEmpty {
                        Button {
                            copyToClipboard(message.serializedJSON)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    }
                }
                .frame(maxWidth: 700, alignment: .leading)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func itemView(for item: MessageItem) -> some View {
        switch item {
        case .text(_, let text):
            Text(text)
                .textSelection(.enabled)
        case .codeBlock(let id, let block):
            codeBlockView(id: id.uuidString, block: block)
        case .grounding(let id, let sources, let queries):
            groundingView(id: id.uuidString, sources: sources, queries: queries)
        case .urlContext(let id, let items):
            urlContextView(id: id.uuidString, items: items)
        }
    }

    @ViewBuilder
    private func codeBlockView(id: String, block: CodeBlock) -> some View {
        let isOpen = expandedItems.contains(id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isOpen { expandedItems.remove(id) } else { expandedItems.insert(id) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal").font(.caption2)
                        Text(block.language).font(.caption2).fontWeight(.medium)
                        Spacer()
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.caption2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isOpen {
                    Button {
                        copyToClipboard(block.code)
                        copiedCodeBlocks.insert(id)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedCodeBlocks.remove(id) }
                    } label: {
                        Image(systemName: copiedCodeBlocks.contains(id) ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(.secondary)

            if isOpen {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(block.code)
                        .font(.caption2).monospaced()
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let result = block.result {
                    Divider()
                    HStack(spacing: 4) {
                        Image(systemName: block.outcome == "OUTCOME_OK" ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(block.outcome == "OUTCOME_OK" ? .green : .red)
                        Text("Output").font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.top, 4)
                    Text(result)
                        .font(.caption2).monospaced()
                        .padding(.horizontal, 8).padding(.bottom, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func groundingView(id: String, sources: [GroundingSource], queries: [String]) -> some View {
        let isOpen = expandedItems.contains(id)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isOpen { expandedItems.remove(id) } else { expandedItems.insert(id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "globe").font(.caption2)
                    Text("Sources (\(sources.count))").font(.caption2).fontWeight(.medium)
                    Spacer()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)

            if isOpen {
                if !queries.isEmpty {
                    Text("Searched: \(queries.joined(separator: " · "))")
                        .font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                }
                ForEach(sources, id: \.uri) { source in
                    if let url = URL(string: source.uri) {
                        Link(destination: url) {
                            HStack(spacing: 4) {
                                Image(systemName: "link").font(.caption2)
                                Text(source.title ?? source.uri).font(.caption2).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func urlContextView(id: String, items: [(url: String, status: String)]) -> some View {
        let isOpen = expandedItems.contains(id)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isOpen { expandedItems.remove(id) } else { expandedItems.insert(id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.magnifyingglass").font(.caption2)
                    Text("URLs fetched (\(items.count))").font(.caption2).fontWeight(.medium)
                    Spacer()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)

            if isOpen {
                ForEach(items, id: \.url) { item in
                    HStack(spacing: 4) {
                        Image(systemName: item.status == "URL_RETRIEVAL_STATUS_SUCCESS"
                              ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(item.status == "URL_RETRIEVAL_STATUS_SUCCESS" ? .green : .red)
                        Text(item.url).font(.caption2).lineLimit(1)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .frame(width: 7, height: 7)
                    .foregroundStyle(.secondary)
                    .opacity(animating ? 1 : 0.3)
                    .scaleEffect(animating ? 1 : 0.7)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(i) * 0.2),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

private func statusColor(_ status: Message.FunctionStatus) -> Color {
    switch status {
    case .calling: .yellow
    case .acting:  .yellow
    case .ended:   .green
    case .failed:  .red
    }
}
