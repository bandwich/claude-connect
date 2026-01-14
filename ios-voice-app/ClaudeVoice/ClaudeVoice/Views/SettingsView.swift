import SwiftUI

struct SettingsView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    @State private var showingScanner = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server Configuration")) {
                    if case .connected = webSocketManager.connectionState {
                        // Show connected IP when connected
                        if let url = webSocketManager.connectedURL {
                            HStack {
                                Text("Connected:")
                                Spacer()
                                Text(formatURL(url))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        // Show Connect button when disconnected
                        Button(action: { showingScanner = true }) {
                            HStack {
                                Spacer()
                                if case .connecting = webSocketManager.connectionState {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                    Text("Connecting...")
                                } else {
                                    Text("Connect")
                                }
                                Spacer()
                            }
                        }
                        .accessibilityIdentifier("Connect")
                        .disabled({
                            if case .connecting = webSocketManager.connectionState {
                                return true
                            }
                            return false
                        }())
                    }
                }

                Section(header: Text("Connection")) {
                    HStack {
                        Text("Status:")
                        Spacer()
                        Text(webSocketManager.connectionState.description)
                            .foregroundColor(connectionColor)
                            .accessibilityIdentifier("connectionStatus")
                    }

                    if case .connected = webSocketManager.connectionState {
                        Button(action: disconnect) {
                            HStack {
                                Spacer()
                                Text("Disconnect")
                                Spacer()
                            }
                        }
                        .accessibilityIdentifier("Disconnect")
                        .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
            .alert("Connection Error", isPresented: $showingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .fullScreenCover(isPresented: $showingScanner) {
                QRScannerView(
                    onCodeScanned: { url in
                        showingScanner = false
                        webSocketManager.connect(url: url)
                    },
                    onCancel: {
                        showingScanner = false
                    }
                )
            }
        }
    }

    private var connectionColor: Color {
        switch webSocketManager.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }

    private func formatURL(_ url: String) -> String {
        // Extract IP from ws://192.168.1.42:8765
        if let range = url.range(of: "ws://") {
            return String(url[range.upperBound...])
        }
        return url
    }

    private func disconnect() {
        webSocketManager.disconnect()
    }
}
