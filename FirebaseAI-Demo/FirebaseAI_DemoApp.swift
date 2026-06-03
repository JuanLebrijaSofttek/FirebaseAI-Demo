//
//  FirebaseAI_DemoApp.swift
//  FirebaseAI-Demo
//
//  Created by Juan Ignacio Lebrija Muraira on 02/06/26.
//

import SwiftUI
import FirebaseCore
import Darwin

@main
struct FirebaseAI_DemoApp: App {
    init() {
        // Writing to a stdio MCP subprocess whose read end has closed raises SIGPIPE,
        // whose default action terminates the app. Ignore it so the write surfaces as
        // a catchable EPIPE error instead.
        signal(SIGPIPE, SIG_IGN)
        FirebaseApp.configure()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
