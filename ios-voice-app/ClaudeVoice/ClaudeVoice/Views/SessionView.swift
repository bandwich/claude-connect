// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
import SwiftUI

struct SessionView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @StateObject private var audioPlayer = AudioPlayer()

    let project: Project
    let session: Session
    @Binding var selectedSessionBinding: Session?  // Use binding to avoid closure recreation

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

            // Bottom mic area
            VStack(spacing: 16) {
                if let error = syncError {
                    // Error state - show error instead of mic
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                    .accessibilityIdentifier("syncError")
                } else if !isSessionSynced && !session.isNewSession {
                    // Syncing state
                    VStack(spacing: 8) {
                        ProgressView()
                    }
                    .accessibilityIdentifier("syncStatus")
                } else {
                    // Normal state - show mic
                    Button(action: toggleRecording) {
                        Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic")
                            .font(.system(size: 32))
                            .foregroundColor(micColor)
                    }
                    .accessibilityLabel(speechRecognizer.isRecording ? "Stop" : "Tap to Talk")
                    .disabled(!canRecord)
                }
            }
            .frame(height: 100)
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))
        }
        .customNavigationBarInline(
            title: session.title,
            breadcrumb: "/\(project.name)",
            onBack: { selectedSessionBinding = nil }
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
        .onChange(of: webSocketManager.connectionState) { _, newState in
            // Retry sync when connection is established (for resumed sessions)
            if case .connected = newState, !session.isNewSession {
                print("[SessionView] Connection established, attempting sync")
                syncSession()
            }
        }
    }

    private var micColor: Color {
        if !canRecord { return .gray }
        return speechRecognizer.isRecording ? .red : .primary
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
        print("[SessionView] setupView called, isNewSession=\(session.isNewSession)")

        // Load message history and sync (skip for new sessions - no history yet)
        if !session.isNewSession {
            webSocketManager.onSessionHistoryReceived = { messages in
                self.messages = messages
            }
            webSocketManager.requestSessionHistory(folderName: project.folderName, sessionId: session.id)

            // Auto-resume session in tmux (existing sessions only)
            // Note: syncSession() will check connection state and retry via onChange if not connected
            syncSession()
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
            print("[SessionView] syncSession: Not connected yet, will retry when connected")
            // Don't set syncError here - we'll retry when connected
            return
        }

        // Don't sync again if already syncing or synced
        guard !isSyncing && !isSessionSynced else {
            print("[SessionView] syncSession: Already syncing or synced, skipping")
            return
        }

        print("[SessionView] syncSession: Starting sync for session \(session.id)")
        isSyncing = true
        syncError = nil

        webSocketManager.onSessionActionResult = { response in
            isSyncing = false
            if response.success {
                // Session synced - connection_status broadcast will update activeSessionId
                print("[SessionView] Session synced successfully")
            } else {
                syncError = response.error ?? "Failed to sync"
                print("[SessionView] Failed to sync session: \(response.error ?? "Unknown error")")
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
        HStack(alignment: .top, spacing: 8) {
            if message.role == "user" {
                Spacer()
                Text("›")
                    .foregroundColor(.secondary)
                Text(message.content)
                    .foregroundColor(.primary)
            } else {
                Text(message.content)
                    .padding(12)
                    .background(Color(.systemGray5))
                    .cornerRadius(12)
                Spacer()
            }
        }
        .accessibilityIdentifier("messageBubble")
    }
}
