import SwiftUI

struct SettingsView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    @State private var showingScanner = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    // Server Configuration Section
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Server Configuration")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal)
                            .padding(.top, 16)
                            .padding(.bottom, 8)

                        VStack(spacing: 0) {
                            if case .connected = webSocketManager.connectionState {
                                if let url = webSocketManager.connectedURL {
                                    HStack {
                                        Text("Connected:")
                                        Spacer()
                                        Text(formatURL(url))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding()
                                    .background(Color(.secondarySystemGroupedBackground))
                                }
                            } else {
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
                                .padding()
                                .background(Color(.secondarySystemGroupedBackground))
                                .accessibilityIdentifier("Connect")
                            }
                        }
                        .cornerRadius(10)
                        .padding(.horizontal)
                    }

                    // Connection Section
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Connection")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal)
                            .padding(.top, 24)
                            .padding(.bottom, 8)

                        VStack(spacing: 0) {
                            HStack {
                                Text("Status:")
                                Spacer()
                                Text(webSocketManager.connectionState.description)
                                    .foregroundColor(connectionColor)
                                    .accessibilityIdentifier("connectionStatus")
                            }
                            .padding()
                            .background(Color(.secondarySystemGroupedBackground))

                            if case .connected = webSocketManager.connectionState {
                                Divider()
                                    .padding(.leading)

                                Button(action: disconnect) {
                                    HStack {
                                        Spacer()
                                        Text("Disconnect")
                                        Spacer()
                                    }
                                }
                                .padding()
                                .background(Color(.secondarySystemGroupedBackground))
                                .accessibilityIdentifier("Disconnect")
                                .foregroundColor(.red)
                            }
                        }
                        .cornerRadius(10)
                        .padding(.horizontal)
                    }

                    // Usage Section (only when connected)
                    if case .connected = webSocketManager.connectionState {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text("Usage")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)

                                Spacer()

                                if webSocketManager.isLoadingUsage {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Button(action: { webSocketManager.requestUsage() }) {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.footnote)
                                    }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 24)
                            .padding(.bottom, 8)

                            VStack(spacing: 0) {
                                if let usage = webSocketManager.usageStats {
                                    UsageRow(
                                        title: "Current Session",
                                        percentage: usage.session.percentage,
                                        resetsAt: usage.session.resetsAt,
                                        timezone: usage.session.timezone
                                    )

                                    Divider().padding(.leading)

                                    UsageRow(
                                        title: "This Week (All Models)",
                                        percentage: usage.weekAllModels.percentage,
                                        resetsAt: usage.weekAllModels.resetsAt,
                                        timezone: usage.weekAllModels.timezone
                                    )

                                    Divider().padding(.leading)

                                    UsageRow(
                                        title: "This Week (Sonnet)",
                                        percentage: usage.weekSonnetOnly.percentage,
                                        resetsAt: nil,
                                        timezone: nil
                                    )

                                    if usage.cached {
                                        Divider().padding(.leading)

                                        HStack {
                                            Text("Last updated")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            if let ts = usage.timestamp {
                                                Text(formatTimestamp(ts))
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding()
                                        .background(Color(.secondarySystemGroupedBackground))
                                    }
                                } else {
                                    HStack {
                                        Spacer()
                                        ProgressView()
                                        Spacer()
                                    }
                                    .padding()
                                    .background(Color(.secondarySystemGroupedBackground))
                                }
                            }
                            .cornerRadius(10)
                            .padding(.horizontal)
                        }
                        .accessibilityIdentifier("usageSection")
                    }

                    Spacer(minLength: 32)
                }
            }
            .background(Color(.systemGroupedBackground))
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
            .onAppear {
                // Auto-fetch usage when settings opens (if connected)
                if case .connected = webSocketManager.connectionState {
                    webSocketManager.requestUsage()
                }
            }
            .onChange(of: webSocketManager.connectionState) { _, newState in
                // Fetch usage when connection is established (e.g., after QR scan)
                if case .connected = newState {
                    webSocketManager.requestUsage()
                }
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

    private func formatTimestamp(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func disconnect() {
        webSocketManager.disconnect()
    }
}

struct UsageRow: View {
    let title: String
    let percentage: Int?
    let resetsAt: String?
    let timezone: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)

            HStack {
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color(.systemGray5))
                            .frame(height: 8)
                            .cornerRadius(4)

                        Rectangle()
                            .fill(progressColor)
                            .frame(width: geometry.size.width * progressFraction, height: 8)
                            .cornerRadius(4)
                    }
                }
                .frame(height: 8)

                Text("\(percentage ?? 0)%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            if let resets = resetsAt {
                Text("Resets \(resets)\(timezone != nil ? " (\(formatTimezone(timezone!)))" : "")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var progressFraction: CGFloat {
        CGFloat(percentage ?? 0) / 100.0
    }

    private var progressColor: Color {
        guard let pct = percentage else { return .gray }
        if pct < 50 { return .green }
        if pct < 80 { return .yellow }
        return .red
    }

    private func formatTimezone(_ tz: String) -> String {
        // Shorten "America/Los_Angeles" to "PT"
        switch tz {
        case "America/Los_Angeles": return "PT"
        case "America/New_York": return "ET"
        case "America/Chicago": return "CT"
        case "America/Denver": return "MT"
        default: return tz
        }
    }
}
