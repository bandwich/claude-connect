// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectsListView.swift
import SwiftUI

struct ProjectsListView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    @State private var projects: [Project] = []
    @State private var selectedProject: Project?
    @State private var showingSessionsList = false
    @State private var showingSettings = false
    @State private var showingAddProject = false
    @State private var newProjectName = ""
    @State private var isCreating = false

    var body: some View {
        Group {
            if case .connected = webSocketManager.connectionState {
                ZStack(alignment: .bottomTrailing) {
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
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)

                    // Floating add button
                    Button(action: { showingAddProject = true }) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 20))
                            .foregroundColor(.primary)
                            .frame(width: 50, height: 50)
                            .background(Color(.systemBackground))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color(.separator), lineWidth: 1)
                            )
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                    .accessibilityLabel("Add Project")
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack {
                    Text("Projects")
                        .font(.title2)
                        .fontWeight(.medium)
                    Spacer()
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityIdentifier("settingsButton")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.light)
        .sheet(isPresented: $showingSettings) {
            SettingsView(webSocketManager: webSocketManager)
        }
        .alert("New Project", isPresented: $showingAddProject) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) {
                newProjectName = ""
            }
            Button("Create") {
                createProject()
            }
        } message: {
            Text("Enter a name for the new project")
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
                ProjectDetailView(
                    webSocketManager: webSocketManager,
                    project: project,
                    showingBinding: $showingSessionsList
                )
            }
        }
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isCreating else {
            newProjectName = ""
            return
        }

        isCreating = true

        webSocketManager.onSessionActionResult = { response in
            isCreating = false
            newProjectName = ""

            if response.success {
                // Refresh projects list
                webSocketManager.requestProjects()
            }
        }

        webSocketManager.addProject(name: name)
    }
}
