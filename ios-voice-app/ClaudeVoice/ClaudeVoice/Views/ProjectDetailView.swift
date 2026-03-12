// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectDetailView.swift
import SwiftUI

enum ProjectTab: String, CaseIterable {
    case sessions = "Sessions"
    case files = "Files"
}

struct ProjectDetailView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let project: Project
    @Binding var showingBinding: Bool

    @State private var selectedTab: ProjectTab = .sessions
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(ProjectTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Tab content
            switch selectedTab {
            case .sessions:
                SessionsContentView(
                    webSocketManager: webSocketManager,
                    project: project
                )
            case .files:
                FilesView(
                    webSocketManager: webSocketManager,
                    project: project
                )
            }
        }
        .customNavigationBar(
            title: selectedTab.rawValue,
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
        .sheet(isPresented: $showingSettings) {
            SettingsView(webSocketManager: webSocketManager)
        }
    }
}

// Extract SessionsListView content into a reusable view
struct SessionsContentView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let project: Project

    @State private var sessions: [Session] = []
    @State private var selectedSession: Session?
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
        .alert("Session Error", isPresented: Binding(
            get: { sessionError != nil },
            set: { if !$0 { sessionError = nil } }
        )) {
            Button("OK") { sessionError = nil }
        } message: {
            Text(sessionError ?? "")
        }
    }

    private func createNewSession() {
        guard !isCreating else { return }
        isCreating = true

        webSocketManager.onSessionActionResult = { response in
            isCreating = false
            if response.success {
                selectedSession = Session.newSession()
            } else {
                sessionError = response.error ?? "Failed to create session"
            }
        }

        webSocketManager.newSession(projectPath: project.path)
    }
}
