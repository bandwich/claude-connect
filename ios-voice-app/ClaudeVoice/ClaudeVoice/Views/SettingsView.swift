import SwiftUI

struct SettingsView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    @AppStorage("serverIP") private var serverIP = ""
    @AppStorage("serverPort") private var serverPort = 8765

    @State private var tempServerIP = ""
    @State private var tempServerPort = "8765"
    @State private var showingAlert = false
    @State private var alertMessage = ""

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server Configuration")) {
                    HStack {
                        Text("IP Address:")
                        TextField("192.168.1.100", text: $tempServerIP)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("Server IP Address")
                    }

                    HStack {
                        Text("Port:")
                        TextField("8765", text: $tempServerPort)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("Port")
                    }
                }

                Section(header: Text("Connection")) {
                    HStack {
                        Text("Status:")
                        Spacer()
                        Text(webSocketManager.connectionState.description)
                            .foregroundColor(connectionColor)
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
                    } else {
                        Button(action: connectToServer) {
                            HStack {
                                Spacer()
                                if case .connecting = webSocketManager.connectionState {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                }
                                Text(connectionButtonText)
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

                Section(header: Text("Instructions")) {
                    Text("1. Make sure your server is running")
                    Text("2. Enter the IP address shown by the server")
                    Text("3. Keep the default port (8765)")
                    Text("4. Tap Connect")
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
            .onAppear {
                tempServerIP = serverIP
                tempServerPort = String(serverPort)
            }
            .alert("Connection Error", isPresented: $showingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
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

    private var connectionButtonText: String {
        switch webSocketManager.connectionState {
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        default:
            return "Connect"
        }
    }

    private func connectToServer() {
        guard !tempServerIP.isEmpty else {
            alertMessage = "Please enter a server IP address"
            showingAlert = true
            return
        }

        guard let port = Int(tempServerPort), port > 0, port < 65536 else {
            alertMessage = "Please enter a valid port number (1-65535)"
            showingAlert = true
            return
        }

        serverIP = tempServerIP
        serverPort = port

        webSocketManager.connect(host: serverIP, port: serverPort)
    }

    private func disconnect() {
        webSocketManager.disconnect()
    }
}
