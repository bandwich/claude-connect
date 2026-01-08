// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift
import SwiftUI

struct SessionsListView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let project: Project

    @State private var sessions: [Session] = []
    @State private var selectedSession: Session?
    @State private var showingSettings = false
    @State private var isCreating = false

    var body: some View {
        List(sessions) { session in
            Button(action: {
                selectedSession = session
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

                    Spacer()

                    // Show active indicator if this session is active
                    if webSocketManager.activeSessionId == session.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .accessibilityLabel("Active session")
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())  // Make entire row tappable
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
        .navigationDestination(item: $selectedSession) { session in
            SessionView(
                webSocketManager: webSocketManager,
                project: project,
                session: session
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
            }
        }

        webSocketManager.newSession(projectPath: project.path)
    }
}
