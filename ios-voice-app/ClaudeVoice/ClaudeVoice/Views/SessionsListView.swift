// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift
import SwiftUI

struct SessionsListView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let project: Project

    @State private var sessions: [Session] = []
    @State private var selectedSession: Session?
    @State private var showingSessionView = false
    @State private var showingSettings = false
    @State private var isCreating = false

    var body: some View {
        List(sessions) { session in
            Button(action: {
                selectedSession = session
                showingSessionView = true
            }) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title)
                            .font(.headline)
                            .lineLimit(2)

                        HStack {
                            Text(session.formattedDate)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer()

                            Text("\(session.messageCount) messages")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Show active indicator if this session is open in VSCode
                    if webSocketManager.activeSessionId == session.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .accessibilityLabel("Active in VSCode")
                    }
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button(action: createNewSession) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Session")

                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
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
        .navigationDestination(isPresented: $showingSessionView) {
            if let session = selectedSession {
                SessionView(
                    webSocketManager: webSocketManager,
                    project: project,
                    session: session
                )
            }
        }
    }

    private func createNewSession() {
        guard !isCreating else { return }
        isCreating = true

        webSocketManager.onSessionActionResult = { response in
            isCreating = false
            if response.success {
                // Refresh sessions list
                webSocketManager.requestSessions(folderName: project.folderName)
            }
        }

        webSocketManager.newSession(projectPath: project.path)
    }
}
