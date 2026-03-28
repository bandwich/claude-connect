// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
import SwiftUI
import PhotosUI

struct SessionView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @StateObject private var audioPlayer = AudioPlayer()

    let project: Project
    let session: Session
    @Binding var selectedSessionBinding: Session?  // Use binding to avoid closure recreation

    @State private var effectiveSessionId: String = ""
    @State private var items: [ConversationItem] = []
    @State private var currentTranscript = ""
    @State private var isInitialLoad = true
    @State private var isSyncing = false
    @State private var syncError: String? = nil
    @State private var contextPercentage: Double? = nil
    @State private var permissionResolutions: [String: PermissionCardResolution] = [:]
    @State private var lastVoiceInputText: String = ""
    @State private var lastVoiceInputTime: Date = .distantPast
    @State private var messageText = ""
    @State private var preRecordingText = ""
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var attachedImages: [AttachedImage] = []
    @State private var showingPhotoPicker = false
    @State private var lastProcessedSeq: Int = -1
    @State private var promptTimeoutTask: Task<Void, Never>? = nil
    @State private var completedBackgroundToolIds: Set<String> = []
    @State private var isNearBottom: Bool = true
    @State private var scrollTrackingEnabled: Bool = false
    @State private var scrollViewWidth: CGFloat = 0
    @AppStorage("ttsEnabled") private var ttsEnabled = true
    @State private var isTextFieldFocused: Bool = false
    @State private var selectedCommandPrefix: String? = nil
    @State private var showCommandDropdown: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Message history
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(items) { item in
                                switch item {
                                case .textMessage(let message):
                                    VStack(alignment: .trailing, spacing: 2) {
                                        MessageBubble(message: message)
                                        if message.role == "user" && message.deliveryFailed {
                                            Text("Failed to send")
                                                .font(.caption2)
                                                .foregroundColor(.red)
                                                .padding(.trailing, 8)
                                        }
                                    }
                                    .id(item.id)
                                case .toolUse(_, let tool, let result):
                                    // ToolSearch is internal schema fetching — hide entirely
                                    if tool.name != "ToolSearch" {
                                        ToolUseView(tool: tool, result: result, isBackgroundComplete: completedBackgroundToolIds.contains(tool.id))
                                            .id(item.id)
                                    }
                                case .agentGroup(let agents):
                                    AgentGroupView(agents: agents)
                                        .id(item.id)
                                case .permissionPrompt(_, let request):
                                    // Resolved permission summary (inline cards removed — input bar handles prompts)
                                    if let resolution = permissionResolutions[request.requestId] {
                                        HStack(spacing: 6) {
                                            Image(systemName: resolution.allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                .foregroundColor(resolution.allowed ? .green : .red)
                                                .font(.caption)
                                            Text(resolution.summary)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color(.systemGray6))
                                        .cornerRadius(8)
                                        .accessibilityIdentifier("permissionResolved")
                                    }
                                case .commandResponse(let command, let output, _):
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(command)
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.secondary)
                                        Text(output)
                                            .font(.system(size: 14, design: .monospaced))
                                            .foregroundColor(.primary)
                                            .textSelection(.enabled)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(12)
                                    .padding(.horizontal, 12)
                                    .id(item.id)
                                }
                            }

                            // Activity status indicator
                            if let activity = webSocketManager.activityState,
                               activity.state != "idle" {
                                ActivityStatusView(
                                    state: activity.state,
                                    detail: activity.detail,
                                    onInterrupt: {
                                        webSocketManager.sendInterrupt()
                                    }
                                )
                                .id("activity-status")
                                .transition(.opacity)
                            }

                            // Bottom anchor for scroll-to-bottom button
                            Color.clear
                                .frame(height: 1)
                                .id("bottom-anchor")
                        }
                        .padding()
                        .frame(maxWidth: scrollViewWidth > 0 ? scrollViewWidth : .infinity, alignment: .leading)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .contentMargins(.bottom, 20, for: .scrollContent)
                    .onScrollGeometryChange(for: CGFloat.self) { geo in
                        geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                    } action: { _, dist in
                        if scrollTrackingEnabled {
                            isNearBottom = dist < 400
                        }
                    }
                    .background {
                        GeometryReader { geo in
                            Color.clear.onAppear { scrollViewWidth = geo.size.width }
                                .onChange(of: geo.size.width) { _, w in scrollViewWidth = w }
                        }
                    }

                    if !isNearBottom && scrollTrackingEnabled {
                        Button(action: {
                            withAnimation {
                                proxy.scrollTo("bottom-anchor", anchor: .bottom)
                            }
                        }) {
                            Image(systemName: "chevron.down.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.white, .blue)
                                .shadow(radius: 4)
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 8)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .onChange(of: items.count) { _, _ in
                    if isInitialLoad {
                        isInitialLoad = false
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            scrollTrackingEnabled = true
                        }
                    } else if isNearBottom {
                        withAnimation {
                            proxy.scrollTo("bottom-anchor", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: webSocketManager.activityState?.state) { _, newState in
                    if let state = newState, state != "idle", isNearBottom {
                        withAnimation {
                            proxy.scrollTo("bottom-anchor", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isTextFieldFocused) { _, focused in
                    if focused {
                        // Keyboard appearing — scroll to bottom after layout adjusts
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation {
                                proxy.scrollTo("bottom-anchor", anchor: .bottom)
                            }
                        }
                    }
                }
            }

            Divider()

            // Input bar
            VStack(spacing: 0) {
                if let error = syncError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("syncError")
                } else {
                    switch webSocketManager.inputBarMode {
                    case .disconnected, .syncing:
                        VStack(spacing: 8) {
                            ProgressView()
                        }
                        .frame(height: 100)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("syncStatus")

                    case .permissionPrompt(let request):
                        PermissionCardView(
                            request: request,
                            onResponse: { response in
                                handlePermissionResponse(response, for: request)
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                    case .questionPrompt(let prompt):
                        QuestionCardView(
                            prompt: prompt,
                            onAnswer: { answer in
                                webSocketManager.sendQuestionResponse(
                                    QuestionResponseMessage(requestId: prompt.requestId, answer: answer)
                                )
                                webSocketManager.inputBarMode = .normal
                            },
                            onDismiss: {
                                webSocketManager.sendQuestionResponse(
                                    QuestionResponseMessage(requestId: prompt.requestId, dismissed: true)
                                )
                                webSocketManager.inputBarMode = .normal
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                    case .normal:
                        // Slash command dropdown
                        if showCommandDropdown {
                            let slashFilter = String(messageText.dropFirst())
                            CommandDropdownView(
                                commands: webSocketManager.availableCommands,
                                filter: slashFilter
                            ) { command in
                                messageText = "/\(command.name) "
                                selectedCommandPrefix = "/\(command.name)"
                                showCommandDropdown = false
                            }
                            .padding(.horizontal, 12)
                            .transition(.opacity)
                        }
                        normalInputBar
                    }
                }
            }
            .background(Color(.systemBackground))
        }
        .customNavigationBarInline(
            title: session.title,
            breadcrumb: "/\(project.name)",
            onBack: { selectedSessionBinding = nil }
        ) {
            HStack(spacing: 8) {
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
                        Text(webSocketManager.branch ?? "main")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Ellipsis menu
                if isActiveSession {
                    Menu {
                        Button("Stop Session", role: .destructive) {
                            stopSession()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .enableSwipeBack()
        .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 5, matching: .images)
        .onChange(of: selectedPhotos) { _, newItems in
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        let filename = "photo_\(UUID().uuidString.prefix(8)).jpg"
                        attachedImages.append(AttachedImage(uiImage: uiImage, filename: filename))
                    }
                }
                selectedPhotos = []
            }
        }
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
        .onAppear {
            webSocketManager.currentlyViewingSessionId = session.isNewSession ? nil : session.id
            setupView()
        }
        .onDisappear {
            webSocketManager.currentlyViewingSessionId = nil
            // Stop recording and audio when navigating away
            speechRecognizer.stopRecording()
            audioPlayer.stop()
            // Tell server to cancel any in-progress TTS for this session
            webSocketManager.stopAudio()
        }
        .onChange(of: webSocketManager.connectionState) { _, newState in
            // Retry sync when connection is established (for resumed sessions)
            if case .connected = newState, !session.isNewSession {
                if !items.isEmpty {
                    // Reconnect — already have messages loaded, just fill gaps
                    print("[SessionView] Reconnect: resync from seq \(webSocketManager.lastReceivedSeq)")
                    webSocketManager.requestResync()
                    webSocketManager.handleInputBarSynced()
                } else {
                    // First connection — load full history and sync tmux session
                    print("[SessionView] First connection: loading history")
                    webSocketManager.requestSessionHistory(folderName: project.folderName, sessionId: session.id)
                    syncSession()
                }
            }
        }
        .onChange(of: webSocketManager.inputBarMode) { _, newMode in
            promptTimeoutTask?.cancel()
            if newMode.showsPrompt {
                promptTimeoutTask = Task {
                    try? await Task.sleep(for: .seconds(180))
                    if !Task.isCancelled && webSocketManager.inputBarMode.showsPrompt {
                        webSocketManager.handleInputBarResolved()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var normalInputBar: some View {
        VStack(spacing: 0) {
            // Image previews
            if !attachedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachedImages) { img in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: img.uiImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                Button {
                                    attachedImages.removeAll { $0.id == img.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.black.opacity(0.6)))
                                }
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }

            // Input area with text field and buttons
            HStack(alignment: .bottom, spacing: 8) {
                // Image picker button
                Button {
                    showingPhotoPicker = true
                } label: {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                        .frame(width: 36, height: 36)
                }
                .disabled(speechRecognizer.isRecording)
                .accessibilityIdentifier("imagePickerButton")

                // Text field
                CommandTextField(
                    text: $messageText,
                    isFocused: $isTextFieldFocused,
                    commandPrefix: selectedCommandPrefix,
                    isDisabled: speechRecognizer.isRecording
                ) { newText in
                    if newText.hasPrefix("/") && selectedCommandPrefix == nil {
                        showCommandDropdown = true
                    } else if !newText.hasPrefix("/") {
                        showCommandDropdown = false
                        selectedCommandPrefix = nil
                    } else if selectedCommandPrefix != nil && !newText.hasPrefix(selectedCommandPrefix!) {
                        selectedCommandPrefix = nil
                        showCommandDropdown = true
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(.systemGray6))
                .cornerRadius(20)
                .accessibilityIdentifier("messageTextField")

                // Mic button
                Button(action: toggleRecording) {
                    Image(systemName: speechRecognizer.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 20))
                        .foregroundColor(speechRecognizer.isRecording ? .red : .secondary)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(speechRecognizer.isRecording ? "Stop" : "Tap to Talk")
                .disabled(!speechRecognizer.isRecording && !canRecord)
                .accessibilityIdentifier("micButton")

                // Send button
                if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty {
                    Button(action: sendTextMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(canSend ? .blue : .gray)
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("sendButton")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var canRecord: Bool {
        guard case .connected = webSocketManager.connectionState else { return false }
        return speechRecognizer.isAuthorized
    }

    private var canSend: Bool {
        guard case .connected = webSocketManager.connectionState else { return false }
        let hasText = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !attachedImages.isEmpty
    }

    private var isActiveSession: Bool {
        webSocketManager.activeSessionIds.contains(session.id) || session.isNewSession
    }

    private func stopSession() {
        let sessionId = session.isNewSession ? effectiveSessionId : session.id
        guard !sessionId.isEmpty else { return }
        webSocketManager.stopSession(sessionId: sessionId)
        selectedSessionBinding = nil
    }

    private var isSessionSynced: Bool {
        if session.isNewSession {
            // New session is synced when connected (server may not have assigned ID yet)
            return webSocketManager.connected && (effectiveSessionId.isEmpty || webSocketManager.activeSessionIds.contains(effectiveSessionId))
        } else {
            // Resumed session is synced when it appears in active sessions
            return webSocketManager.activeSessionIds.contains(session.id)
        }
    }

    private func setupView() {
        print("[SessionView] setupView called, isNewSession=\(session.isNewSession)")

        // Initialize effective session ID
        effectiveSessionId = session.id

        // Reset seq tracking for this new view
        lastProcessedSeq = -1
        webSocketManager.lastReceivedSeq = 0

        // Load message history and sync (skip for new sessions - no history yet)
        if !session.isNewSession {
            // Don't show spinner — load history in background, input bar stays usable
            webSocketManager.onSessionHistoryReceived = { richMessages, lineCount in
                // Initialize seq tracking from transcript line count
                // so reconnect resync requests the right range
                if let lineCount = lineCount, lineCount > 0 {
                    self.lastProcessedSeq = lineCount - 1
                    webSocketManager.lastReceivedSeq = lineCount - 1
                    print("[SessionView] Initialized seq tracking: lastProcessedSeq=\(lineCount - 1), lastReceivedSeq=\(lineCount - 1)")
                }
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
                // Mark any tool_use blocks without results as stale
                // (e.g., app reinstalled mid-tool, or result was missed)
                // TODO: duplicated at ~lines 551, 645 — extract into a helper
                for i in 0..<newItems.count {
                    if case .toolUse(let tid, let tool, let result) = newItems[i], result == nil {
                        let staleResult = ToolResultBlock(
                            type: "tool_result",
                            toolUseId: tid,
                            content: "(result not available)",
                            isError: false
                        )
                        newItems[i] = .toolUse(toolId: tid, tool: tool, result: staleResult)
                    }
                }
                self.items = groupAgentItems(newItems)
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

        speechRecognizer.onPartialTranscription = { text in
            // Live update: show partial transcription in text field as user speaks
            let base = preRecordingText
            if base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messageText = text
            } else {
                messageText = base + " " + text
            }
        }

        speechRecognizer.onFinalTranscription = { text in
            // Final result: set definitive text and reset base
            let base = preRecordingText
            if base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messageText = text
            } else {
                messageText = base + " " + text
            }
            preRecordingText = messageText
            currentTranscript = ""
        }

        // Setup audio player
        webSocketManager.onAudioChunk = { [self] chunk in
            if ttsEnabled {
                audioPlayer.receiveAudioChunk(chunk)
            }
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
            if effectiveSessionId.isEmpty {
                // New session: adopt the session ID from the first response
                if let newId = response.sessionId {
                    DispatchQueue.main.async {
                        effectiveSessionId = newId
                        webSocketManager.currentlyViewingSessionId = newId
                    }
                    print("[SessionView] Adopted session ID: \(newId)")
                }
            } else {
                if response.sessionId != effectiveSessionId { return }
            }

            // Seq-based dedup: skip if we already processed this seq
            if let seq = response.seq {
                if seq <= lastProcessedSeq { return }
                lastProcessedSeq = seq
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
                        // Mark any previous non-Task tool_use without a result as stale
                        for i in stride(from: items.count - 1, through: 0, by: -1) {
                            if case .toolUse(let tid, let tool, nil) = items[i], tool.name != "Agent" {
                                let staleResult = ToolResultBlock(
                                    type: "tool_result",
                                    toolUseId: tid,
                                    content: "(result not available)",
                                    isError: false
                                )
                                items[i] = .toolUse(toolId: tid, tool: tool, result: staleResult)
                            }
                        }

                        if toolBlock.name == "Agent" {
                            // Check if last item is already an agentGroup — append to it
                            if case .agentGroup(var agents) = items.last {
                                agents.append(AgentInfo(tool: toolBlock, result: nil))
                                items[items.count - 1] = .agentGroup(agents: agents)
                            }
                            // Check if last item is a single Agent toolUse — merge into group
                            else if case .toolUse(_, let prevTool, let prevResult) = items.last, prevTool.name == "Agent" {
                                let prevAgent = AgentInfo(tool: prevTool, result: prevResult)
                                let newAgent = AgentInfo(tool: toolBlock, result: nil)
                                items[items.count - 1] = .agentGroup(agents: [prevAgent, newAgent])
                            }
                            // Otherwise just append as single toolUse
                            else {
                                items.append(.toolUse(toolId: toolBlock.id, tool: toolBlock, result: nil))
                            }
                        } else {
                            items.append(.toolUse(toolId: toolBlock.id, tool: toolBlock, result: nil))
                        }
                    }
                case .toolResult(let resultBlock):
                    DispatchQueue.main.async {
                        // First check agentGroup items
                        for i in 0..<items.count {
                            if case .agentGroup(var agents) = items[i] {
                                if let agentIdx = agents.firstIndex(where: { $0.tool.id == resultBlock.toolUseId }) {
                                    agents[agentIdx].result = resultBlock
                                    items[i] = .agentGroup(agents: agents)
                                    return
                                }
                            }
                        }
                        // Then check individual toolUse items
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
            if effectiveSessionId.isEmpty {
                if let newId = message.sessionId {
                    DispatchQueue.main.async { effectiveSessionId = newId }
                }
            } else {
                if message.sessionId != effectiveSessionId { return }
            }

            // Seq-based dedup: skip if we already processed this seq
            if let seq = message.seq {
                if seq <= lastProcessedSeq { return }
                lastProcessedSeq = seq
            }

            guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            // Skip server echo of input we already added locally
            if message.content == lastVoiceInputText {
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

        // Handle resync responses (gap recovery on reconnect)
        webSocketManager.onResyncReceived = { [self] resyncResponse in
            print("[SessionView] Resync received: \(resyncResponse.messages.count) messages from seq \(resyncResponse.fromSeq)")
            for msg in resyncResponse.messages {
                // Skip already-processed sequences
                if msg.seq <= lastProcessedSeq { continue }
                lastProcessedSeq = msg.seq

                guard let role = msg.role else { continue }

                if role == "assistant" {
                    // Process assistant content blocks
                    switch msg.content {
                    case .blocks(let blocks):
                        for block in blocks {
                            switch block {
                            case .text(let textBlock):
                                guard !textBlock.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                                let message = SessionHistoryMessage(
                                    role: "assistant",
                                    content: textBlock.text,
                                    timestamp: 0
                                )
                                DispatchQueue.main.async {
                                    items.append(.textMessage(message))
                                }
                            case .toolUse(let toolBlock):
                                DispatchQueue.main.async {
                                    // Mark any previous non-Task tool_use without a result as stale
                                    for i in stride(from: items.count - 1, through: 0, by: -1) {
                                        if case .toolUse(let tid, let tool, nil) = items[i], tool.name != "Agent" {
                                            let staleResult = ToolResultBlock(
                                                type: "tool_result",
                                                toolUseId: tid,
                                                content: "(result not available)",
                                                isError: false
                                            )
                                            items[i] = .toolUse(toolId: tid, tool: tool, result: staleResult)
                                        }
                                    }

                                    if toolBlock.name == "Agent" {
                                        if case .agentGroup(var agents) = items.last {
                                            agents.append(AgentInfo(tool: toolBlock, result: nil))
                                            items[items.count - 1] = .agentGroup(agents: agents)
                                        } else if case .toolUse(_, let prevTool, let prevResult) = items.last, prevTool.name == "Agent" {
                                            let prevAgent = AgentInfo(tool: prevTool, result: prevResult)
                                            let newAgent = AgentInfo(tool: toolBlock, result: nil)
                                            items[items.count - 1] = .agentGroup(agents: [prevAgent, newAgent])
                                        } else {
                                            items.append(.toolUse(toolId: toolBlock.id, tool: toolBlock, result: nil))
                                        }
                                    } else {
                                        items.append(.toolUse(toolId: toolBlock.id, tool: toolBlock, result: nil))
                                    }
                                }
                            case .toolResult(let resultBlock):
                                DispatchQueue.main.async {
                                    // First check agentGroup items
                                    for i in 0..<items.count {
                                        if case .agentGroup(var agents) = items[i] {
                                            if let agentIdx = agents.firstIndex(where: { $0.tool.id == resultBlock.toolUseId }) {
                                                agents[agentIdx].result = resultBlock
                                                items[i] = .agentGroup(agents: agents)
                                                return
                                            }
                                        }
                                    }
                                    // Then check individual toolUse items
                                    if let idx = items.firstIndex(where: {
                                        if case .toolUse(let tid, _, _) = $0 { return tid == resultBlock.toolUseId }
                                        return false
                                    }) {
                                        if case .toolUse(let tid, let tool, _) = items[idx] {
                                            items[idx] = .toolUse(toolId: tid, tool: tool, result: resultBlock)
                                        }
                                    }
                                }
                            default:
                                break
                            }
                        }
                    case .string(let text):
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        let message = SessionHistoryMessage(
                            role: "assistant",
                            content: text,
                            timestamp: 0
                        )
                        DispatchQueue.main.async {
                            items.append(.textMessage(message))
                        }
                    }
                }
                // User messages are skipped in resync — they're already
                // displayed locally (typed by user) or loaded from history
            }
            // After resync, regroup any consecutive Task items
            DispatchQueue.main.async {
                items = groupAgentItems(items)
            }
        }

        // Initialize from existing context stats if available
        if let stats = webSocketManager.contextStats,
           stats.sessionId == session.id {
            self.contextPercentage = stats.contextPercentage
        }

        // Subscribe to context updates
        webSocketManager.onContextUpdate = { stats in
            // Only update if this is for our session
            if stats.sessionId == session.id || stats.sessionId == effectiveSessionId || (session.isNewSession && effectiveSessionId.isEmpty) {
                self.contextPercentage = stats.contextPercentage
            }
        }

        webSocketManager.onTaskCompleted = { toolUseId in
            self.completedBackgroundToolIds.insert(toolUseId)
        }

        // Handle delivery status (mark failed messages)
        webSocketManager.onDeliveryStatus = { [self] status in
            if status.status == "failed" {
                for i in stride(from: items.count - 1, through: 0, by: -1) {
                    if case .textMessage(var msg) = items[i],
                       msg.role == "user",
                       msg.content.contains(status.text) {
                        msg.deliveryFailed = true
                        items[i] = .textMessage(msg)
                        break
                    }
                }
            }
        }

        webSocketManager.onCommandResponse = { command, output in
            items.append(.commandResponse(command: command, output: output))
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

        // If already synced, ensure input bar reflects that
        if isSessionSynced {
            print("[SessionView] syncSession: Already synced, ensuring input bar is ready")
            isSyncing = false
            webSocketManager.handleInputBarSynced()
            return
        }

        // Don't sync again if already syncing
        guard !isSyncing else {
            print("[SessionView] syncSession: Already syncing, skipping")
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
                webSocketManager.handleInputBarSynced()
            } else {
                syncError = response.error ?? "Failed to sync"
                print("[SessionView] Failed to sync session: \(response.error ?? "Unknown error")")
            }
        }

        // If session is already active in tmux, just switch the view — don't re-resume
        if webSocketManager.activeSessionIds.contains(session.id) {
            webSocketManager.viewSession(sessionId: session.id)
        } else {
            webSocketManager.resumeSession(sessionId: session.id, folderName: project.folderName)
        }

        // Timeout: if sync doesn't complete in 10s, fall back to normal input
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            if isSyncing {
                print("[SessionView] syncSession: Timed out, falling back to normal input")
                isSyncing = false
                webSocketManager.handleInputBarSynced()
            }
        }
    }

    private func toggleRecording() {
        if speechRecognizer.isRecording {
            speechRecognizer.stopRecording()
        } else {
            // Stop any TTS playback so mic can take over
            if audioPlayer.isPlaying {
                audioPlayer.stop()
            }
            webSocketManager.voiceState = .idle
            preRecordingText = messageText
            do {
                try speechRecognizer.startRecording()
            } catch {
                print("Failed to start recording: \(error)")
            }
        }
    }

    private func sendTextMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedImages.isEmpty else { return }

        // Slash commands: don't add user message bubble — command_response card handles display
        if text.hasPrefix("/") && attachedImages.isEmpty {
            webSocketManager.sendUserInput(text: text, images: [])
            messageText = ""
            selectedCommandPrefix = nil
            showCommandDropdown = false
            return
        }

        // Build display text for conversation (include image count)
        var displayText = text
        if !attachedImages.isEmpty {
            let imgCount = attachedImages.count
            let suffix = imgCount == 1 ? "1 image" : "\(imgCount) images"
            if displayText.isEmpty {
                displayText = "[\(suffix)]"
            } else {
                displayText += " [\(suffix)]"
            }
        }

        // Add to conversation items locally
        let userMessage = SessionHistoryMessage(
            role: "user",
            content: displayText,
            timestamp: Date().timeIntervalSince1970
        )
        items.append(.textMessage(userMessage))

        // Track for server echo dedup
        lastVoiceInputText = text
        lastVoiceInputTime = Date()

        // Encode images as base64 JPEG
        let imageAttachments = attachedImages.map { img -> ImageAttachment in
            let jpegData = img.uiImage.jpegData(compressionQuality: 0.7) ?? Data()
            return ImageAttachment(
                data: jpegData.base64EncodedString(),
                filename: img.filename
            )
        }

        // Send via WebSocket
        webSocketManager.sendUserInput(text: text, images: imageAttachments)

        // Cancel recording if active — must happen before clearing text so
        // onFinalTranscription doesn't re-populate messageText after send
        if speechRecognizer.isRecording {
            speechRecognizer.cancelRecording()
        }

        // Clear input — resign focus first to prevent TextField's active editing
        // session from overriding the binding update back to the old value
        isTextFieldFocused = false
        messageText = ""
        attachedImages = []
        preRecordingText = ""
        selectedCommandPrefix = nil
        showCommandDropdown = false
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
        // Reset input bar immediately — don't wait for server roundtrip
        webSocketManager.pendingPermission = nil
        webSocketManager.handleInputBarResolved()
    }
}

struct PermissionCardResolution {
    let allowed: Bool
    let summary: String
}

struct ActivityStatusView: View {
    let state: String   // "thinking", "tool_active", "waiting_permission"
    let detail: String
    let onInterrupt: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)

            Text(displayText)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            Button(action: onInterrupt) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.red)
                    .padding(6)
                    .background(Color(.systemGray5))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Interrupt")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var displayText: String {
        if !detail.isEmpty {
            return detail
        }
        switch state {
        case "thinking":
            return "Thinking..."
        case "tool_active":
            return "Working..."
        case "waiting_permission":
            return "Waiting for permission..."
        default:
            return "Working..."
        }
    }
}

struct AttachedImage: Identifiable {
    let id = UUID()
    let uiImage: UIImage
    let filename: String
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
