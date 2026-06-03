//
//  ChatViewModel.swift
//  FirebaseAI-Demo
//
//  Created by Juan Ignacio Lebrija Muraira on 02/06/26.
//

import FirebaseAILogic
import SwiftUI

struct CodeBlock {
    let code: String
    let language: String
    var result: String? = nil
    var outcome: String? = nil
}

struct GroundingSource {
    let title: String?
    let uri: String
}

enum MessageItem: Identifiable {
    case text(id: UUID, text: String)
    case codeBlock(id: UUID, CodeBlock)
    case grounding(id: UUID, sources: [GroundingSource], queries: [String])
    case urlContext(id: UUID, items: [(url: String, status: String)])

    var id: String {
        switch self {
        case .text(let id, _):         return id.uuidString
        case .codeBlock(let id, _):    return id.uuidString
        case .grounding(let id, _, _): return id.uuidString
        case .urlContext(let id, _):   return id.uuidString
        }
    }
}

struct Message: Identifiable {
    let id = UUID()
    let role: Role
    var text: String
    var contentItems: [MessageItem] = []
    var isStreaming: Bool = false
    var functionStatus: FunctionStatus = .calling
    var functionArgs: String? = nil
    var functionResult: String? = nil

    enum Role { case user, model, function }
    enum FunctionStatus { case calling, acting, ended, failed }
}

extension Message {
    /// A structured JSON dump of how this message is stored, including every content item
    /// in order. Intended for copying and sharing for review.
    var serializedJSON: String {
        var dict: [String: Any] = [
            "role": "\(role)",
            "isStreaming": isStreaming,
            "text": text
        ]

        var items: [[String: Any]] = []
        for item in contentItems {
            switch item {
            case .text(_, let text):
                items.append(["type": "text", "text": text])
            case .codeBlock(_, let block):
                var d: [String: Any] = ["type": "codeBlock", "language": block.language, "code": block.code]
                if let result = block.result { d["result"] = result }
                if let outcome = block.outcome { d["outcome"] = outcome }
                items.append(d)
            case .grounding(_, let sources, let queries):
                items.append([
                    "type": "grounding",
                    "queries": queries,
                    "sources": sources.map { ["title": $0.title ?? NSNull(), "uri": $0.uri] as [String: Any] }
                ])
            case .urlContext(_, let urls):
                items.append([
                    "type": "urlContext",
                    "items": urls.map { ["url": $0.url, "status": $0.status] }
                ])
            }
        }
        dict["contentItems"] = items

        if role == .function {
            dict["functionStatus"] = "\(functionStatus)"
            if let args = functionArgs { dict["functionArgs"] = args }
            if let result = functionResult { dict["functionResult"] = result }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

@Observable
@MainActor
final class ChatViewModel {
    var messages: [Message] = []
    var isLoading: Bool = false

    private var model: GenerativeModel
    private var chat: Chat
    private var streamTask: Task<Void, Never>?

    private let mcpManager = MCPManager()
    /// Server connection statuses, surfaced to the MCP management UI.
    var mcpStatuses: [MCPServerStatus] = []

    /// Max tool-call rounds per user message before the agentic loop stops.
    private let maxTurns = 10

    init() {
        let m = FirebaseAI.firebaseAI(backend: .vertexAI(location: "global"))
            .generativeModel(
                modelName: "gemini-3.5-flash",
                tools: [
                    .functionDeclarations([fetchWeatherTool, echoTool]),
                    .googleSearch(),
                    .urlContext(),
                    .codeExecution()
                ]
            )
        model = m
        chat = m.startChat()

        // Discover MCP tools asynchronously; the model is rebuilt once they arrive.
        Task { await connectMCPAndRebuild() }
    }

    // MARK: - MCP integration

    /// Connect all stored MCP servers (seeding built-ins on first run) and rebuild
    /// the model with their tools merged in.
    func connectMCPAndRebuild() async {
        await mcpManager.connectAll(MCPServerStore.loadOrSeed())
        mcpStatuses = Array(mcpManager.statuses.values)
        rebuildModel()
    }

    /// Connect (or reconnect) a single server, then refresh the model's tool set.
    func connectServer(_ config: MCPServerConfig) async {
        await mcpManager.connect(config)
        mcpStatuses = Array(mcpManager.statuses.values)
        rebuildModel()
    }

    /// Disconnect a single server (removing its tools from the model).
    func disconnectServer(_ id: UUID) async {
        await mcpManager.disconnect(id)
        mcpStatuses = Array(mcpManager.statuses.values)
        rebuildModel()
    }

    /// Disconnect all MCP servers (and terminate stdio subprocesses). Call on teardown.
    func disconnectMCP() async {
        await mcpManager.disconnectAll()
    }

    private func rebuildModel() {
        let mcpDecls = mcpManager.aggregatedFunctionDeclarations()
        let m = FirebaseAI.firebaseAI(backend: .vertexAI(location: "global"))
            .generativeModel(
                modelName: "gemini-3.5-flash",
                tools: [
                    .functionDeclarations([fetchWeatherTool, echoTool] + mcpDecls),
                    .googleSearch(),
                    .urlContext(),
                    .codeExecution()
                ]
            )
        // Preserve the existing conversation when swapping the model's tool set.
        let history = chat.history
        model = m
        chat = m.startChat(history: history)
    }

    func clearChat() {
        messages.removeAll()
    }

    /// Launches a cancellable streaming send. The running task is retained so `cancel()`
    /// can stop it mid-stream.
    func send(_ userText: String) {
        streamTask = Task { await self.sendMessage(userText) }
    }

    /// Cancels the in-flight stream, if any, cutting it out completely.
    func cancel() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Appends streamed text to the message, merging into the trailing text item if the
    /// previous item was also text (so consecutive deltas accumulate), otherwise starting
    /// a new text item. This preserves interleaving with code/tool items.
    private func appendText(_ delta: String, to index: Int) {
        guard !delta.isEmpty else { return }
        messages[index].text += delta
        if case .text(let id, let existing)? = messages[index].contentItems.last {
            messages[index].contentItems[messages[index].contentItems.count - 1] = .text(id: id, text: existing + delta)
        } else {
            messages[index].contentItems.append(.text(id: UUID(), text: delta))
        }
    }

    /// Input to a single streaming turn: either the user's text, or the tool results
    /// from the previous turn (sent back with role "user", as Vertex AI requires).
    private enum TurnInput {
        case user(String)
        case toolResults([FunctionResponsePart])
    }

    private func sendMessage(_ userText: String) async {
        guard !userText.isEmpty else { return }
        messages.append(Message(role: .user, text: userText))
        messages.append(Message(role: .model, text: ""))
        var currentIndex = messages.count - 1
        messages[currentIndex].isStreaming = true
        isLoading = true

        // Tracks whichever model message is currently streaming so we can stop its
        // typing indicator at every exit point (early return, error, completion).
        var streamingIndex = currentIndex
        defer {
            isLoading = false
            if messages.indices.contains(streamingIndex) {
                messages[streamingIndex].isStreaming = false
            }
        }

        var input: TurnInput = .user(userText)
        var turn = 0

        while turn < maxTurns {
            let calls: [FunctionCallPart]
            do {
                calls = try await streamTurn(input, into: currentIndex)
            } catch {
                messages[currentIndex].text = "Error: \(error.localizedDescription)"
                return
            }
            if Task.isCancelled { return }

            // No tool calls → this turn is the model's final answer. Done.
            guard !calls.isEmpty else { return }

            // Convert the current (possibly text-bearing) bubble into a function bubble.
            let functionNames = calls.map { $0.name }.joined(separator: ", ")
            let argsString = calls.map { formatJSON($0.args) }.joined(separator: "\n\n")
            messages[currentIndex] = Message(role: .function, text: functionNames,
                                             functionStatus: .acting, functionArgs: argsString)
            let funcIndex = currentIndex

            // Execute every call (local handlers or MCP), in order.
            var responses: [FunctionResponsePart] = []
            for call in calls {
                if Task.isCancelled { return }
                if let response = await handleFunctionCall(call) {
                    responses.append(response)
                }
            }

            guard !responses.isEmpty else {
                messages[funcIndex].functionStatus = .failed
                return
            }
            messages[funcIndex].functionResult = responses.map { formatJSON($0.response) }.joined(separator: "\n\n")
            messages[funcIndex].functionStatus = .ended

            // Open a fresh model bubble for the next turn.
            messages.append(Message(role: .model, text: ""))
            currentIndex = messages.count - 1
            messages[currentIndex].isStreaming = true
            streamingIndex = currentIndex

            input = .toolResults(responses)
            turn += 1
        }

        // Hit the turn cap without a final text answer.
        if turn >= maxTurns {
            appendText("⚠️ Reached the \(maxTurns)-turn tool limit; stopping.", to: currentIndex)
        }
    }

    /// Streams one model turn into `index`, accumulating text/code/grounding/url-context
    /// content items in arrival order and returning any function calls the model emitted.
    private func streamTurn(_ input: TurnInput, into index: Int) async throws -> [FunctionCallPart] {
        let stream: AsyncThrowingStream<GenerateContentResponse, Error>
        let source: String
        switch input {
        case .user(let text):
            stream = try chat.sendMessageStream(text)
            source = "turn-user"
        case .toolResults(let responses):
            // Vertex AI requires role "user" for function responses (not "function")
            stream = try chat.sendMessageStream([ModelContent(role: "user", parts: responses)])
            source = "turn-tool-results"
        }

        var calls: [FunctionCallPart] = []
        var groundingAdded = false
        var urlContextAdded = false

        for try await chunk in stream {
            if Task.isCancelled { return calls }
            logChunk(chunk, source: source)
            calls += chunk.functionCalls

            if let parts = chunk.candidates.first?.content.parts {
                for part in parts {
                    if let textPart = part as? TextPart, !textPart.isThought {
                        appendText(textPart.text, to: index)
                    } else if let codePart = part as? ExecutableCodePart {
                        let block = CodeBlock(code: codePart.code, language: codePart.language.description)
                        messages[index].contentItems.append(.codeBlock(id: UUID(), block))
                    } else if let resultPart = part as? CodeExecutionResultPart,
                              let lastIdx = messages[index].contentItems.indices.reversed().first(where: {
                                  if case .codeBlock = messages[index].contentItems[$0] { return true }
                                  return false
                              }) {
                        if case .codeBlock(let id, var block) = messages[index].contentItems[lastIdx] {
                            block.result = resultPart.output
                            block.outcome = resultPart.outcome.description
                            messages[index].contentItems[lastIdx] = .codeBlock(id: id, block)
                        }
                    }
                }
            }

            if !groundingAdded, let grounding = chunk.candidates.first?.groundingMetadata {
                let sources = grounding.groundingChunks.compactMap { chunk -> GroundingSource? in
                    guard let web = chunk.web, let uri = web.uri else { return nil }
                    return GroundingSource(title: web.title, uri: uri)
                }
                messages[index].contentItems.append(.grounding(id: UUID(), sources: sources, queries: grounding.webSearchQueries))
                groundingAdded = true
            }

            if !urlContextAdded, let urlCtx = chunk.candidates.first?.urlContextMetadata {
                let items = urlCtx.urlMetadata.map {
                    (url: $0.retrievedURL?.absoluteString ?? "unknown",
                     status: $0.retrievalStatus.rawValue)
                }
                messages[index].contentItems.append(.urlContext(id: UUID(), items: items))
                urlContextAdded = true
            }
        }

        return calls
    }

    /// Prints absolutely everything Firebase AI returns in a streamed chunk, so nothing
    /// goes unseen. Uses the 🛰️ marker for every Firebase AI response.
    private func logChunk(_ chunk: GenerateContentResponse, source: String) {
        print("🛰️ ───── Firebase AI chunk [\(source)] ─────")
        print("🛰️ RAW: \(String(reflecting: chunk))")
        print("🛰️ modelVersion: \(chunk.modelVersion)")

        if let text = chunk.text { print("🛰️ text: \(text)") }
        if let thought = chunk.thoughtSummary { print("🛰️ thoughtSummary: \(thought)") }

        for (i, call) in chunk.functionCalls.enumerated() {
            print("🛰️ functionCall[\(i)]: name=\(call.name) id=\(call.functionId ?? "nil") args=\(call.args)")
        }
        for (i, data) in chunk.inlineDataParts.enumerated() {
            print("🛰️ inlineDataPart[\(i)]: mimeType=\(data.mimeType) bytes=\(data.data.count)")
        }

        if let usage = chunk.usageMetadata {
            print("🛰️ usageMetadata: prompt=\(usage.promptTokenCount) candidates=\(usage.candidatesTokenCount) thoughts=\(usage.thoughtsTokenCount) toolUse=\(usage.toolUsePromptTokenCount) total=\(usage.totalTokenCount)")
        }
        if let feedback = chunk.promptFeedback {
            print("🛰️ promptFeedback: blockReason=\(String(describing: feedback.blockReason)) message=\(feedback.blockReasonMessage ?? "nil") safety=\(feedback.safetyRatings)")
        }

        for (ci, candidate) in chunk.candidates.enumerated() {
            print("🛰️ candidate[\(ci)] finishReason=\(String(describing: candidate.finishReason)) finishMessage=\(candidate.finishMessage ?? "nil")")
            print("🛰️ candidate[\(ci)] safetyRatings=\(candidate.safetyRatings)")
            if let citation = candidate.citationMetadata {
                print("🛰️ candidate[\(ci)] citationMetadata=\(citation)")
            }
            if let grounding = candidate.groundingMetadata {
                print("🛰️ candidate[\(ci)] groundingMetadata=\(grounding)")
            }
            if let urlCtx = candidate.urlContextMetadata {
                print("🛰️ candidate[\(ci)] urlContextMetadata=\(urlCtx)")
            }
            for (pi, part) in candidate.content.parts.enumerated() {
                print("🛰️ candidate[\(ci)] part[\(pi)] type=\(type(of: part)) value=\(String(reflecting: part))")
            }
        }
        print("🛰️ ───── end chunk [\(source)] ─────")
    }

    private func handleFunctionCall(_ call: FunctionCallPart) async -> FunctionResponsePart? {
        switch call.name {
        case "fetchWeather":
            guard case let .object(location) = call.args["location"],
                  case let .string(city) = location["city"],
                  case let .string(state) = location["state"],
                  case let .string(date) = call.args["date"]
            else { return nil }
            return FunctionResponsePart(
                name: call.name,
                response: fetchWeather(city: city, state: state, date: date),
                functionId: call.functionId
            )
        case "echo":
            guard case let .string(input) = call.args["input"] else { return nil }
            return FunctionResponsePart(
                name: call.name,
                response: echo(input: input),
                functionId: call.functionId
            )
        default:
            // Unknown tool name → dispatch to MCP.
            do {
                let response = try await mcpManager.callTool(name: call.name, args: call.args)
                return FunctionResponsePart(name: call.name, response: response, functionId: call.functionId)
            } catch {
                print("⚠️ MCP tool call failed for \(call.name): \(error)")
                return nil
            }
        }
    }
}

private func formatJSON(_ object: JSONObject, indent: Int = 0) -> String {
    let pad = String(repeating: "  ", count: indent)
    return object.sorted { $0.key < $1.key }.map { key, value in
        switch value {
        case .object(let nested):
            return "\(pad)\(key):\n\(formatJSON(nested, indent: indent + 1))"
        default:
            return "\(pad)\(key): \(formatJSONValue(value))"
        }
    }.joined(separator: "\n")
}

private func formatJSONValue(_ value: JSONValue) -> String {
    switch value {
    case .null:          return "null"
    case .bool(let b):   return b ? "true" : "false"
    case .number(let n): return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
    case .string(let s): return s
    case .array(let a):  return "[\(a.map { formatJSONValue($0) }.joined(separator: ", "))]"
    case .object(let o): return formatJSON(o)
    }
}
