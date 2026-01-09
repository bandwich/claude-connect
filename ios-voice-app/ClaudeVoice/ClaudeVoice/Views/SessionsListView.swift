// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift
import SwiftUI

struct SessionsListView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let project: Project
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [Session] = []
    @State private var selectedSession: Session?
    @State private var showingSettings = false
    @State private var isCreating = false

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
            onBack: { dismiss() }
        ) {
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.secondary)
            }
        }
        .enableSwipeBack()
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
