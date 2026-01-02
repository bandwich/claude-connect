// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectsListView.swift
import SwiftUI

struct ProjectsListView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    @State private var projects: [Project] = []
    @State private var selectedProject: Project?
    @State private var showingSessionsList = false
    @State private var showingSettings = false

    var body: some View {
        Group {
            if case .connected = webSocketManager.connectionState {
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
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)

                    Text("Not Connected")
                        .font(.title2)
                        .fontWeight(.medium)

                    Text("Configure server settings to connect")
                        .font(.body)
                        .foregroundColor(.secondary)

                    Button("Open Settings") {
                        showingSettings = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape.fill")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(webSocketManager: webSocketManager)
        }
        .onAppear {
            webSocketManager.onProjectsReceived = { projects in
                self.projects = projects
            }
            if case .connected = webSocketManager.connectionState {
                webSocketManager.requestProjects()
            }
        }
        .onChange(of: webSocketManager.connectionState) { oldState, newState in
            if case .connected = newState {
                webSocketManager.requestProjects()
            }
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
