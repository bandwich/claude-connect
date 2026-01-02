// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectsListView.swift
import SwiftUI

struct ProjectsListView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    @State private var projects: [Project] = []
    @State private var selectedProject: Project?
    @State private var showingSessionsList = false

    var body: some View {
        List(projects) { project in
            Button(action: {
                selectedProject = project
                showingSessionsList = true
            }) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(project.name)
                            .font(.headline)
                        Text(project.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Text("\(project.sessionCount)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(8)
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Projects")
        .onAppear {
            webSocketManager.onProjectsReceived = { projects in
                self.projects = projects
            }
            webSocketManager.requestProjects()
        }
        .navigationDestination(isPresented: $showingSessionsList) {
            if let project = selectedProject {
                SessionsListView(
                    webSocketManager: webSocketManager,
                    project: project
                )
            }
        }
    }
}
