// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
import SwiftUI

struct SessionView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @StateObject private var audioPlayer = AudioPlayer()

    let project: Project
    let session: Session
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [SessionHistoryMessage] = []
    @State private var currentTranscript = ""
    @State private var isInitialLoad = true
    @State private var isSyncing = false
    @State private var syncError: String? = nil
    @State private var branchName: String = "main"  // Placeholder for now

    var body: some View {
        VStack(spacing: 0) {
            // Message history
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    guard let lastMessage = messages.last else { return }

                    if isInitialLoad {
                        // Initial load: scroll instantly without animation
                        isInitialLoad = false
                        DispatchQueue.main.async {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    } else {
                        // New messages during session: animate
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Voice input area
            VStack(spacing: 12) {
                if !currentTranscript.isEmpty {
                    Text(currentTranscript)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }

                // Show sync status or voice state
                if isSyncing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Syncing...")
                            .accessibilityIdentifier("syncStatus")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                } else if let error = syncError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .accessibilityIdentifier("syncError")
                } else if let statusText = webSocketManager.outputState.statusText {
                    // Show output state when active (thinking, using tool, speaking)
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("outputStatus")
                } else {
                    // Show voice state when idle
                    Text(webSocketManager.voiceState.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("voiceState")
                }

                Button(action: toggleRecording) {
                    HStack {
                        Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic")
                        Text(speechRecognizer.isRecording ? "Stop" : "Tap to Talk")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(buttonColor)
                    .cornerRadius(12)
                }
                .accessibilityLabel(speechRecognizer.isRecording ? "Stop" : "Tap to Talk")
                .padding(.horizontal, 40)
                .disabled(!canRecord)
            }
            .padding(.vertical)
            .background(Color(.systemBackground))
        }
        .customNavigationBarInline(
            title: session.title,
            breadcrumb: "/\(project.name)",
            onBack: { dismiss() }
        ) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(branchName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .enableSwipeBack()
        .sheet(item: $webSocketManager.pendingPermission) { request in
            PermissionPromptView(request: request) { response in
                // Add permission response to message history
                let decisionText = response.decision == .allow ? "✓ Allowed" : "✗ Denied"
                let responseMessage = SessionHistoryMessage(
                    role: "assistant",
                    content: "\(decisionText): \(permissionDescription(for: request))",
                    timestamp: response.timestamp
                )
                messages.append(responseMessage)

                webSocketManager.sendPermissionResponse(response)
            }
        }
        .onChange(of: webSocketManager.pendingPermission) { _, newValue in
            // Add permission request to message history when it arrives
            if let request = newValue {
                let requestMessage = SessionHistoryMessage(
                    role: "assistant",
                    content: "⏳ Permission requested: \(permissionDescription(for: request))",
                    timestamp: request.timestamp
                )
                messages.append(requestMessage)
            }
        }
        .onAppear(perform: setupView)
    }

    private var buttonColor: Color {
        if !canRecord { return .gray }
        return speechRecognizer.isRecording ? .red : .blue
    }

    private var canRecord: Bool {
        guard isSessionSynced else { return false }
        guard webSocketManager.outputState.canSendVoiceInput else { return false }
        if case .connected = webSocketManager.connectionState {
            return speechRecognizer.isAuthorized && !audioPlayer.isPlaying
        }
        return false
    }

    private var isSessionSynced: Bool {
        if session.isNewSession {
            // New session is synced when connected and no specific session is active
            // (meaning the new claude session we just started is running)
            return webSocketManager.connected && webSocketManager.activeSessionId == nil
        } else {
            // Resumed session is synced when activeSessionId matches
            return webSocketManager.activeSessionId == session.id
        }
    }

    private func setupView() {
        // Load message history (skip for new sessions - no history yet)
        if !session.isNewSession {
            webSocketManager.onSessionHistoryReceived = { messages in
                self.messages = messages
            }
            webSocketManager.requestSessionHistory(folderName: project.folderName, sessionId: session.id)

            // Auto-resume session in tmux (only for existing sessions)
            // New sessions are already running from the newSession() call
            if !session.isNewSession {
                syncSession()
            } else {
                // For new sessions, just mark as ready (tmux already started)
                isSyncing = false
            }
        }

        // Setup speech recognizer
        speechRecognizer.onRecordingStarted = { [weak webSocketManager] in
            DispatchQueue.main.async {
                webSocketManager?.voiceState = .listening
            }
        }

        speechRecognizer.onRecordingStopped = { [weak webSocketManager] in
            DispatchQueue.main.async {
                if webSocketManager?.voiceState == .listening {
                    webSocketManager?.voiceState = .idle
                }
            }
        }

        speechRecognizer.onFinalTranscription = { text in
            currentTranscript = text

            // Add user message to list immediately
            let userMessage = SessionHistoryMessage(
                role: "user",
                content: text,
                timestamp: Date().timeIntervalSince1970
            )
            messages.append(userMessage)

            webSocketManager.sendVoiceInput(text: text)

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if currentTranscript == text {
                    currentTranscript = ""
                }
            }
        }

        // Setup audio player
        webSocketManager.onAudioChunk = { chunk in
            audioPlayer.receiveAudioChunk(chunk)
        }

        audioPlayer.onPlaybackStarted = {
            DispatchQueue.main.async {
                webSocketManager.isPlayingAudio = true
                webSocketManager.voiceState = .speaking
                webSocketManager.outputState = .speaking
            }
        }

        audioPlayer.onPlaybackFinished = {
            DispatchQueue.main.async {
                webSocketManager.isPlayingAudio = false
                webSocketManager.voiceState = .idle
                webSocketManager.outputState = .idle
            }
        }

        // Subscribe to real-time assistant responses
        webSocketManager.onAssistantResponse = { [self] response in
            // Filter: only accept messages for the current session
            // For new sessions (id is empty), accept messages with no session_id
            // For resumed sessions, the session_id must match
            if session.isNewSession {
                // New session: accept messages with nil sessionId
                if response.sessionId != nil {
                    return  // Message is for a different session
                }
            } else {
                // Resumed session: sessionId must match
                if response.sessionId != session.id {
                    return  // Message is for a different session
                }
            }

            // Extract text from content blocks
            var textContent = ""
            for block in response.contentBlocks {
                switch block {
                case .text(let textBlock):
                    textContent += textBlock.text
                case .thinking:
                    break
                case .toolUse:
                    break
                }
            }

            guard !textContent.isEmpty else { return }

            // Create message and append to list
            let message = SessionHistoryMessage(
                role: "assistant",
                content: textContent,
                timestamp: response.timestamp
            )

            DispatchQueue.main.async {
                messages.append(message)
            }
        }
    }

    private func syncSession() {
        // Don't skip even if appears synced - server state may be stale

        // Check if WebSocket is connected (not tmux session status)
        guard case .connected = webSocketManager.connectionState else {
            syncError = "Not connected to server"
            return
        }

        isSyncing = true
        syncError = nil

        webSocketManager.onSessionActionResult = { response in
            isSyncing = false
            if response.success {
                // Session synced - connection_status broadcast will update activeSessionId
                print("Session synced successfully")
            } else {
                syncError = response.error ?? "Failed to sync"
                print("Failed to sync session: \(response.error ?? "Unknown error")")
            }
        }

        webSocketManager.resumeSession(sessionId: session.id, folderName: project.folderName)
    }

    private func toggleRecording() {
        if speechRecognizer.isRecording {
            speechRecognizer.stopRecording()
        } else {
            do {
                try speechRecognizer.startRecording()
            } catch {
                print("Failed to start recording: \(error)")
            }
        }
    }

    private func permissionDescription(for request: PermissionRequest) -> String {
        switch request.promptType {
        case .bash:
            if let command = request.toolInput?.command {
                // Truncate long commands
                let truncated = command.count > 50 ? String(command.prefix(50)) + "..." : command
                return "`\(truncated)`"
            }
            return "Run command"
        case .edit:
            if let path = request.context?.filePath {
                return "Edit \(path)"
            }
            return "Edit file"
        case .write:
            if let path = request.context?.filePath {
                return "Create \(path)"
            }
            return "Create file"
        case .task:
            if let desc = request.toolInput?.description {
                let truncated = desc.count > 50 ? String(desc.prefix(50)) + "..." : desc
                return "Agent: \(truncated)"
            }
            return "Run agent"
        case .question:
            if let text = request.question?.text {
                let truncated = text.count > 50 ? String(text.prefix(50)) + "..." : text
                return truncated
            }
            return "Answer question"
        }
    }
}

struct MessageBubble: View {
    let message: SessionHistoryMessage

    var body: some View {
        HStack {
            if message.role == "user" {
                Spacer()
            }

            Text(message.content)
                .padding(12)
                .background(message.role == "user" ? Color.blue : Color(.systemGray5))
                .foregroundColor(message.role == "user" ? .white : .primary)
                .cornerRadius(16)
                .accessibilityIdentifier("messageBubble")

            if message.role == "assistant" {
                Spacer()
            }
        }
    }
}
