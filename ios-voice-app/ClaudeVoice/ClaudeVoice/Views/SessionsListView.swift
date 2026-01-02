// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift
import SwiftUI

struct SessionsListView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let project: Project

    @State private var sessions: [Session] = []

    var body: some View {
        List(sessions) { session in
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
            .padding(.vertical, 4)
        }
        .navigationTitle(project.name)
        .onAppear {
            webSocketManager.onSessionsReceived = { sessions in
                self.sessions = sessions
            }
            webSocketManager.requestSessions(projectPath: project.path)
        }
    }
}
