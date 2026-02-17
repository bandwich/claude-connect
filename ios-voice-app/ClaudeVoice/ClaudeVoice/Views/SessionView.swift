// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
import SwiftUI

struct SessionView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @StateObject private var audioPlayer = AudioPlayer()

    let project: Project
    let session: Session
    @Binding var selectedSessionBinding: Session?  // Use binding to avoid closure recreation

    @State private var items: [ConversationItem] = []
    @State private var currentTranscript = ""
    @State private var isInitialLoad = true
    @State private var isSyncing = false
    @State private var syncError: String? = nil
    @State private var branchName: String = "main"  // Placeholder for now
    @State private var contextPercentage: Double? = nil
    @State private var permissionResolutions: [String: PermissionCardResolution] = [:]
    @State private var lastVoiceInputText: String = ""
    @State private var lastVoiceInputTime: Date = .distantPast

    var body: some View {
        VStack(spacing: 0) {
            // Message history
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(items) { item in
                            switch item {
                            case .textMessage(let message):
                                MessageBubble(message: message)
                                    .id(item.id)
                            case .toolUse(_, let tool, let result):
                                ToolUseView(tool: tool, result: result)
                                    .id(item.id)
                            case .permissionPrompt(_, let request):
                                PermissionCardView(
                                    request: request,
                                    resolved: permissionResolutions[request.requestId],
                                    onResponse: { response in
                                        handlePermissionResponse(response, for: request)
                                    }
                                )
                                .id(item.id)
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: items.count) { _, _ in
                    guard let lastItem = items.last else { return }

                    if isInitialLoad {
                        isInitialLoad = false
                        DispatchQueue.main.async {
                            proxy.scrollTo(lastItem.id, anchor: .bottom)
                        }
                    } else {
                        withAnimation {
                            proxy.scrollTo(lastItem.id, anchor: .bottom)
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
                        Image(systemName: speechRecognizer.isRecording ? "stop.fill" : "mic")
                            .font(.system(size: 32))
                            .foregroundColor(micColor)
                    }
                    .accessibilityLabel(speechRecognizer.isRecording ? "Stop" : "Tap to Talk")
                    .disabled(!speechRecognizer.isRecording && !canRecord)
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
            HStack(spacing: 12) {
                // Context indicator
                if let pct = contextPercentage {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(contextColor(pct))
                            .frame(width: 8, height: 8)
                        Text("\(Int(max(0, 100 - pct)))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityIdentifier("contextIndicator")
                }

                // Branch name
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(branchName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .enableSwipeBack()
        .onChange(of: webSocketManager.pendingPermission) { _, newValue in
            if let request = newValue {
                // Only add if not already in items (prevents duplicates on reconnect)
                let alreadyExists = items.contains(where: {
                    if case .permissionPrompt(let id, _) = $0 { return id == request.requestId }
                    return false
                })
                if !alreadyExists {
                    items.append(.permissionPrompt(requestId: request.requestId, request: request))
                }
            }
        }
        .onAppear(perform: setupView)
        .onDisappear {
            // Stop recording and audio when navigating away
            speechRecognizer.stopRecording()
            audioPlayer.stop()
        }
        .onChange(of: webSocketManager.connectionState) { _, newState in
            // Retry sync when connection is established (for resumed sessions)
            if case .connected = newState, !session.isNewSession {
                print("[SessionView] Connection established, attempting sync")
                // Re-fetch session history to clear stale "Running..." tool_use items
                webSocketManager.requestSessionHistory(folderName: project.folderName, sessionId: session.id)
                syncSession()
            }
        }
    }

    private var micColor: Color {
        if speechRecognizer.isRecording { return .red }
        if !canRecord { return .gray }
        return .primary
    }

    private var canRecord: Bool {
        guard isSessionSynced else { return false }
        guard webSocketManager.outputState.canSendVoiceInput else { return false }
        guard webSocketManager.voiceState == .idle else { return false }
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
            webSocketManager.onSessionHistoryReceived = { richMessages in
                var newItems: [ConversationItem] = []
                for msg in richMessages {
                    if msg.role == "tool_result" {
                        // Find matching tool_use and update it with result
                        if let blocks = msg.contentBlocks,
                           let block = blocks.first,
                           let toolUseId = block.toolUseId {
                            let resultBlock = ToolResultBlock(
                                type: "tool_result",
                                toolUseId: toolUseId,
                                content: block.content ?? msg.content,
                                isError: block.isError
                            )
                            if let idx = newItems.firstIndex(where: {
                                if case .toolUse(let tid, _, _) = $0 { return tid == toolUseId }
                                return false
                            }) {
                                if case .toolUse(let tid, let tool, _) = newItems[idx] {
                                    newItems[idx] = .toolUse(toolId: tid, tool: tool, result: resultBlock)
                                }
                            }
                        }
                    } else if let blocks = msg.contentBlocks {
                        // Assistant message with structured blocks
                        for block in blocks {
                            if block.type == "text", let text = block.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                newItems.append(.textMessage(SessionHistoryMessage(
                                    role: msg.role,
                                    content: text,
                                    timestamp: msg.timestamp
                                )))
                            } else if block.type == "tool_use", let id = block.id, let name = block.name {
                                let toolBlock = ToolUseBlock(
                                    type: "tool_use",
                                    id: id,
                                    name: name,
                                    input: block.input ?? [:]
                                )
                                newItems.append(.toolUse(toolId: id, tool: toolBlock, result: nil))
                            }
                        }
                    } else if !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Simple text message (skip empty/whitespace-only)
                        newItems.append(.textMessage(SessionHistoryMessage(
                            role: msg.role,
                            content: msg.content,
                            timestamp: msg.timestamp
                        )))
                    }
                }
                // Re-add pending permission card if history reload would wipe it
                if let pending = self.webSocketManager.pendingPermission {
                    if self.permissionResolutions[pending.requestId] == nil {
                        newItems.append(.permissionPrompt(requestId: pending.requestId, request: pending))
                    }
                }
                self.items = newItems
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
            lastVoiceInputText = text
            lastVoiceInputTime = Date()

            let userMessage = SessionHistoryMessage(
                role: "user",
                content: text,
                timestamp: Date().timeIntervalSince1970
            )
            items.append(.textMessage(userMessage))

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
        webSocketManager.onStopAudio = {
            audioPlayer.stop()
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
            if session.isNewSession {
                if response.sessionId != nil { return }
            } else {
                if response.sessionId != session.id { return }
            }

            for block in response.contentBlocks {
                switch block {
                case .text(let textBlock):
                    guard !textBlock.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let message = SessionHistoryMessage(
                        role: "assistant",
                        content: textBlock.text,
                        timestamp: response.timestamp
                    )
                    DispatchQueue.main.async {
                        items.append(.textMessage(message))
                    }
                case .thinking:
                    break
                case .toolUse(let toolBlock):
                    DispatchQueue.main.async {
                        items.append(.toolUse(toolId: toolBlock.id, tool: toolBlock, result: nil))
                    }
                case .toolResult(let resultBlock):
                    DispatchQueue.main.async {
                        // Find matching tool_use and update with result
                        if let idx = items.firstIndex(where: {
                            if case .toolUse(let tid, _, _) = $0 { return tid == resultBlock.toolUseId }
                            return false
                        }) {
                            if case .toolUse(let tid, let tool, _) = items[idx] {
                                items[idx] = .toolUse(toolId: tid, tool: tool, result: resultBlock)
                            }
                        }
                    }
                case .unknown:
                    break
                }
            }
        }

        // Subscribe to real-time user messages (terminal-typed input)
        webSocketManager.onUserMessage = { [self] message in
            // Filter: only accept messages for the current session
            if session.isNewSession {
                if message.sessionId != nil { return }
            } else {
                if message.sessionId != session.id { return }
            }

            guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            // Skip server echo of voice input we already added locally
            if message.content == lastVoiceInputText &&
               Date().timeIntervalSince(lastVoiceInputTime) < 10 {
                lastVoiceInputText = ""  // Clear so only first echo is filtered
                return
            }

            let userMsg = SessionHistoryMessage(
                role: "user",
                content: message.content,
                timestamp: message.timestamp
            )
            DispatchQueue.main.async {
                items.append(.textMessage(userMsg))
            }
        }

        // Subscribe to context updates
        webSocketManager.onContextUpdate = { stats in
            // Only update if this is for our session
            if stats.sessionId == session.id || (session.isNewSession && webSocketManager.activeSessionId == nil) {
                self.contextPercentage = stats.contextPercentage
            }
        }

        // Handle permission resolved from terminal (only if not already resolved from app)
        webSocketManager.onPermissionResolved = { resolved in
            DispatchQueue.main.async {
                if resolved.answeredIn == "terminal" && permissionResolutions[resolved.requestId] == nil {
                    permissionResolutions[resolved.requestId] = PermissionCardResolution(
                        allowed: true,
                        summary: "Answered in terminal"
                    )
                }
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

    private func contextColor(_ percentage: Double) -> Color {
        let remaining = 100 - percentage
        if remaining > 50 {
            return .green
        } else if remaining > 20 {
            return .yellow
        } else {
            return .red
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
            if let path = request.context?.filePath ?? request.toolInput?.filePath {
                return "Edit \(path)"
            }
            return "Edit file"
        case .write:
            if let path = request.context?.filePath ?? request.toolInput?.filePath {
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

    private func handlePermissionResponse(_ response: PermissionResponse, for request: PermissionRequest) {
        let allowed = response.decision == .allow
        let summary = "\(allowed ? "Allowed" : "Denied"): \(permissionDescription(for: request))"
        permissionResolutions[request.requestId] = PermissionCardResolution(
            allowed: allowed,
            summary: summary
        )
        webSocketManager.sendPermissionResponse(response)
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
                Text(markdownString(message.content))
                    .padding(12)
                    .background(Color(.systemGray5))
                    .cornerRadius(12)
                Spacer()
            }
        }
        .accessibilityIdentifier("messageBubble")
    }

    private func markdownString(_ text: String) -> AttributedString {
        var s = text
        // ## heading → **heading**
        s = s.replacingOccurrences(of: #"(?m)^#{1,6}\s+(.+)$"#, with: "**$1**", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var result = try? AttributedString(markdown: s, options: options) else {
            return AttributedString(text)
        }
        // Scale down code spans: monospace at ~85% of body size
        let codeSize = UIFont.preferredFont(forTextStyle: .body).pointSize * 0.85
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                result[run.range].font = .system(size: codeSize, design: .monospaced)
            }
        }
        return result
    }
}
