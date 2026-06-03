# FirebaseAI Demo

A simple AI chat client for iOS built with the **Firebase AI Logic** SDK and **MCP (Model Context Protocol)** support.

## Overview

This demo app showcases how to build a conversational AI interface using:

- **Firebase AI Logic** — Google's Firebase SDK for integrating generative AI (Gemini) directly into mobile apps, handling authentication, safety, and model access through your Firebase project.
- **MCP (Model Context Protocol)** — An open protocol that lets the AI connect to external tools and data sources. The app includes an MCP manager that can connect to local (stdio) and remote (OAuth-authenticated) MCP servers, giving the model access to real-world capabilities.

## Features

- Chat UI with streaming responses
- Tool/function calling (built-in `echo` and `fetchWeather` functions)
- MCP server management — add, connect, and use MCP servers at runtime
- OAuth flow for authenticated MCP servers
- Schema conversion between MCP tool definitions and Firebase AI tool format

## Project Structure

```
FirebaseAI-Demo/
├── Views/           # SwiftUI views (ContentView, MessageBubble, MCPServersView)
├── ViewModel/       # ChatViewModel and Firebase AI Logic integration
├── MCP/             # MCP client (MCPManager, StdioLauncher, OAuthCoordinator, SchemaConverter)
└── Functions/       # Built-in tool definitions (Echo, FetchWeather)
```

## Setup

1. Create a Firebase project at [console.firebase.google.com](https://console.firebase.google.com).
2. Enable the **Vertex AI** or **Gemini Developer API** in your Firebase project.
3. Download `GoogleService-Info.plist` from your Firebase project and add it to the `FirebaseAI-Demo/` target folder.
4. Open `FirebaseAI-Demo.xcodeproj` in Xcode and run on a simulator or device.

> **Note:** `GoogleService-Info.plist` is excluded from version control. Each developer must supply their own from their Firebase project.

## Requirements

- Xcode 16+
- iOS 17+
- A Firebase project with AI Logic enabled
