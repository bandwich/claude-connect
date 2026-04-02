import SwiftUI

@main
struct ClaudeConnectApp: App {
    @StateObject private var webSocketManager = WebSocketManager()
    @AppStorage("serverIP") private var serverIP = ""
    @AppStorage("serverPort") private var serverPort = 8765
    @Environment(\.scenePhase) private var scenePhase

    // For E2E tests: environment variables override saved settings
    private var effectiveServerIP: String {
        ProcessInfo.processInfo.environment["SERVER_HOST"] ?? serverIP
    }
    private var effectiveServerPort: Int {
        if let portStr = ProcessInfo.processInfo.environment["SERVER_PORT"],
           let port = Int(portStr) {
            return port
        }
        return serverPort
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ProjectsListView(webSocketManager: webSocketManager)
            }
            .onAppear {
                // Disable UIKit animations in test mode for faster E2E tests
                if ProcessInfo.processInfo.environment["INTEGRATION_TEST_MODE"] == "1" {
                    UIView.setAnimationsEnabled(false)
                }

                // Auto-connect if we have settings and not already connected
                // Environment variables (for E2E tests) override saved settings
                if !effectiveServerIP.isEmpty && webSocketManager.connectionState == .disconnected {
                    webSocketManager.connect(host: effectiveServerIP, port: effectiveServerPort)
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    webSocketManager.reconnectIfNeeded()
                }
            }
        }
    }
}
