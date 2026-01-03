import SwiftUI

@main
struct ClaudeVoiceApp: App {
    @StateObject private var webSocketManager = WebSocketManager()
    @AppStorage("serverIP") private var serverIP = ""
    @AppStorage("serverPort") private var serverPort = 8765

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ProjectsListView(webSocketManager: webSocketManager)
            }
            .onAppear {
                // Auto-connect if we have saved settings
                if !serverIP.isEmpty {
                    webSocketManager.connect(host: serverIP, port: serverPort)
                }
            }
        }
    }
}
