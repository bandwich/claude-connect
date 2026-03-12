// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift
import SwiftUI

struct SessionsListView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let project: Project
    @Binding var showingBinding: Bool  // Use binding to avoid @Environment(\.dismiss) render loop

    @State private var sessions: [Session] = []
    @State private var selectedSession: Session?
    @State private var showingSettings = false
    @State private var isCreating = false
    @State private var sessionError: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List(sessions) { session in
                Button(action: {
                    selectedSession = session
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Text("\(session.messageCount) messages")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text(TimeFormatter.relativeTimeString(from: session.timestamp))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .padding(.top, 4)

            // Floating add button
            Button(action: createNewSession) {
                Image(systemName: "plus")
                    .font(.system(size: 20))
                    .foregroundColor(.primary)
                    .frame(width: 50, height: 50)
                    .background(Color(.systemBackground))
                    .cornerRadius(25)
                    .overlay(
                        Circle()
                            .stroke(Color(.separator), lineWidth: 1)
                    )
            }
            .padding(.trailing, 20)
            .padding(.bottom, 20)
            .accessibilityLabel("New Session")
        }
        .customNavigationBar(
            title: "Sessions",
            breadcrumb: "/\(project.name)",
            onBack: { showingBinding = false }
        ) {
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.secondary)
            }
            .accessibilityIdentifier("settingsButton")
        }
        .enableSwipeBack()
        .alert("Session Error", isPresented: Binding(
            get: { sessionError != nil },
            set: { if !$0 { sessionError = nil } }
        )) {
            Button("OK") { sessionError = nil }
        } message: {
            Text(sessionError ?? "")
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(webSocketManager: webSocketManager)
        }
        .onAppear {
            webSocketManager.onSessionsReceived = { sessions in
                self.sessions = sessions
            }
            webSocketManager.requestSessions(folderName: project.folderName)
        }
        .navigationDestination(item: $selectedSession) { session in
            SessionView(
                webSocketManager: webSocketManager,
                project: project,
                session: session,
                selectedSessionBinding: $selectedSession
            )
        }
    }

    private func createNewSession() {
        guard !isCreating else { return }
        isCreating = true

        webSocketManager.onSessionActionResult = { response in
            isCreating = false
            if response.success {
                // Navigate to the new session
                selectedSession = Session.newSession()
            } else {
                sessionError = response.error ?? "Failed to create session"
            }
        }

        webSocketManager.newSession(projectPath: project.path)
    }
}
