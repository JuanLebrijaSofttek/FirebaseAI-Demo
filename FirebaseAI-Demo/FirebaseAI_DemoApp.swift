//
//  FirebaseAI_DemoApp.swift
//  FirebaseAI-Demo
//
//  Created by Juan Ignacio Lebrija Muraira on 02/06/26.
//

import SwiftUI
import FirebaseCore

@main
struct FirebaseAI_DemoApp: App {
    init() {
        FirebaseApp.configure()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
