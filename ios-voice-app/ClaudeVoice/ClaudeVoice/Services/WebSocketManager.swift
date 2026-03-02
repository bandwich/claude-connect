import Foundation
import Combine

class WebSocketManager: NSObject, ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected {
        didSet {
            print("🔄 connectionState didSet: \(oldValue) -> \(connectionState)")
        }
    }

    @Published var voiceState: VoiceState = .idle {
        didSet {
            logToFile("🔄 voiceState didSet: \(oldValue.description) -> \(voiceState.description)")
            print("🔄 voiceState didSet: \(oldValue.description) -> \(voiceState.description)")
        }
    }

    @Published var connected: Bool = false {
        didSet {
            print("🔄 connected didSet: \(oldValue) -> \(connected)")
        }
    }
    @Published var activeSessionId: String? = nil {
        didSet {
            print("🔄 activeSessionId didSet: \(oldValue ?? "nil") -> \(activeSessionId ?? "nil")")
        }
    }
    @Published var branch: String? = nil
    @Published var outputState: ClaudeOutputState = .idle {
        didSet {
            print("🔄 outputState didSet: \(oldValue) -> \(outputState)")
        }
    }

    var onAudioChunk: ((AudioChunkMessage) -> Void)?
    var onStopAudio: (() -> Void)?
    var onStatusUpdate: ((StatusMessage) -> Void)?
    var onAssistantResponse: ((AssistantResponseMessage) -> Void)?  // NEW
    var onProjectsReceived: (([Project]) -> Void)?
    var onSessionsReceived: (([Session]) -> Void)?
    var onSessionHistoryReceived: (([SessionHistoryMessageRich]) -> Void)?
    var onSessionActionResult: ((SessionActionResponse) -> Void)?
    var onConnectionStatusReceived: ((ConnectionStatus) -> Void)?
    var onPermissionRequest: ((PermissionRequest) -> Void)?
    var onPermissionResolved: ((PermissionResolved) -> Void)?
    var onDirectoryListing: ((DirectoryListingResponse) -> Void)?
    var onFileContents: ((FileContentsResponse) -> Void)?
    var onContextUpdate: ((ContextStats) -> Void)?
    var onUsageUpdate: ((UsageStats) -> Void)?
    var onUserMessage: ((UserMessage) -> Void)?
    var onActivityStatus: ((ActivityStatusMessage) -> Void)?
    @Published var pendingPermission: PermissionRequest? = nil {
        didSet {
            print("🔄 pendingPermission didSet: \(oldValue?.requestId ?? "nil") -> \(pendingPermission?.requestId ?? "nil")")
        }
    }
    @Published var contextStats: ContextStats? = nil
    @Published var usageStats: UsageStats? = nil
    @Published var inputBarMode: InputBarMode = .normal
    @Published var activityState: ActivityStatusMessage? = nil
    @Published var isLoadingUsage: Bool = false
    @Published var lastReceivedSeq: Int = 0
    var onResyncReceived: ((ResyncResponse) -> Void)?
    var isPlayingAudio: Bool = false // Tracks if audio is currently playing
    private var lastContentBlocks: [ContentBlock] = []  // NEW: store for future UI

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var currentURL: URL?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var shouldReconnect = false
    @Published var connectedURL: String? = nil

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        // Connection timeout - fail fast if server is unreachable
        config.timeoutIntervalForRequest = 10  // 10 seconds for connection
        // Resource timeout - longer to handle TTS generation and audio streaming
        config.timeoutIntervalForResource = 120  // 2 minutes for full request
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    deinit {
        // Prevent reconnection attempts during deallocation
        shouldReconnect = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
    }

    func connect(host: String, port: Int) {
        guard let url = URL(string: "ws://\(host):\(port)") else {
            DispatchQueue.main.async {
                self.connectionState = .error("Invalid URL")
            }
            return
        }

        // Disconnect existing connection if any
        if webSocketTask != nil {
            disconnect()
        }

        shouldReconnect = true
        reconnectAttempts = 0
        connectToURL(url)
    }

    func connect(url: String) {
        guard let wsURL = URL(string: url) else {
            DispatchQueue.main.async {
                self.connectionState = .error("Invalid URL")
            }
            return
        }

        // Disconnect existing connection if any
        if webSocketTask != nil {
            disconnect()
        }

        shouldReconnect = true
        reconnectAttempts = 0
        connectedURL = url
        connectToURL(wsURL)
    }

    private func connectToURL(_ url: URL) {
        print("🔌 CONNECTING TO: \(url.absoluteString)")

        // Ensure we're on the main thread for URLSession operations
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.connectToURL(url)
            }
            return
        }

        // Verify we should still attempt connection
        guard shouldReconnect || reconnectAttempts == 0 else {
            connectionState = .disconnected
            return
        }

        // Validate URLSession is still valid
        guard let session = urlSession else {
            connectionState = .error("URLSession not initialized")
            shouldReconnect = false
            return
        }

        connectionState = .connecting

        // Store the URL for reconnection attempts
        currentURL = url

        // Clean up any existing task before creating a new one
        if let existingTask = webSocketTask {
            existingTask.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
        }

        // Create new WebSocket task
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveMessage()
    }

    func disconnect() {
        shouldReconnect = false
        connectionState = .disconnected
        voiceState = .idle
        activityState = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        currentURL = nil
        connectedURL = nil
    }

    func sendVoiceInput(text: String) {
        print("🔵 WebSocketManager.sendVoiceInput: ✅ CALLED with text: '\(text)'")
        logToFile("🔵 sendVoiceInput: START text='\(text)'")

        let message = VoiceInputMessage(text: text)

        guard let jsonData = try? JSONEncoder().encode(message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ WebSocketManager: Failed to encode voice input message")
            logToFile("❌ sendVoiceInput: ENCODE FAILED")
            return
        }

        print("🔵 WebSocketManager: Encoded JSON: \(jsonString)")
        logToFile("🔵 sendVoiceInput: JSON=\(jsonString)")

        print("🔵 WebSocketManager: webSocketTask exists: \(webSocketTask != nil)")
        logToFile("🔵 sendVoiceInput: webSocketTask=\(webSocketTask != nil ? "EXISTS" : "NIL")")

        let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(wsMessage) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                // Don't set error state if we intentionally disconnected
                if case .disconnected = self.connectionState {
                    return
                }
                print("❌ WebSocketManager: Send FAILED: \(error.localizedDescription)")
                self.logToFile("❌ sendVoiceInput: SEND ERROR: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.connectionState = .error(error.localizedDescription)
                }
            } else {
                print("✅ WebSocketManager: Send SUCCESS!")
                self.logToFile("✅ sendVoiceInput: SEND SUCCESS")
            }
        }

        print("🔵 WebSocketManager: send() initiated, waiting for callback...")
        logToFile("🔵 sendVoiceInput: send() initiated")
    }

    func sendUserInput(text: String, images: [ImageAttachment] = []) {
        let message = UserInputMessage(text: text, images: images)

        guard let jsonData = try? JSONEncoder().encode(message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("Failed to encode user input message")
            return
        }

        let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(wsMessage) { [weak self] error in
            if let error = error {
                if case .disconnected = self?.connectionState { return }
                print("Send user input error: \(error.localizedDescription)")
            }
        }
    }

    func sendPreference(ttsEnabled: Bool) {
        let message = SetPreferenceMessage(ttsEnabled: ttsEnabled)

        guard let jsonData = try? JSONEncoder().encode(message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("Failed to encode preference message")
            return
        }

        let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(wsMessage) { error in
            if let error = error {
                print("Send preference error: \(error)")
            }
        }
    }

    // MARK: - Session Management Methods

    func requestProjects() {
        let message = ["type": "list_projects"]
        sendJSON(message)
    }

    func requestSessions(folderName: String) {
        let message: [String: Any] = [
            "type": "list_sessions",
            "folder_name": folderName
        ]
        sendJSON(message)
    }

    func requestSessionHistory(folderName: String, sessionId: String) {
        let message: [String: Any] = [
            "type": "get_session",
            "folder_name": folderName,
            "session_id": sessionId
        ]
        sendJSON(message)
    }

    // MARK: - Session Action Methods

    func closeSession() {
        let message = ["type": "close_session"]
        sendJSON(message)
    }

    func newSession(projectPath: String) {
        let message: [String: Any] = [
            "type": "new_session",
            "project_path": projectPath
        ]
        sendJSON(message)
    }

    func resumeSession(sessionId: String, folderName: String) {
        let message: [String: Any] = [
            "type": "resume_session",
            "session_id": sessionId,
            "folder_name": folderName
        ]
        sendJSON(message)
    }

    func addProject(name: String) {
        let message: [String: Any] = [
            "type": "add_project",
            "name": name
        ]
        sendJSON(message)
    }

    func listDirectory(path: String) {
        let message: [String: Any] = [
            "type": "list_directory",
            "path": path
        ]
        sendJSON(message)
    }

    func readFile(path: String) {
        let message: [String: Any] = [
            "type": "read_file",
            "path": path
        ]
        sendJSON(message)
    }

    func sendInterrupt() {
        let message = ["type": "interrupt"]
        sendJSON(message)
    }

    func requestResync() {
        let message: [String: Any] = [
            "type": "resync",
            "from_seq": lastReceivedSeq
        ]
        sendJSON(message)
    }

    func requestUsage() {
        isLoadingUsage = true
        let message = ["type": "usage_request"]
        sendJSON(message)
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let jsonString = String(data: data, encoding: .utf8) else {
            print("❌ Failed to encode JSON")
            return
        }

        let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(wsMessage) { error in
            if let error = error {
                print("Send error: \(error)")
            }
        }
    }

    func sendPermissionResponse(_ response: PermissionResponse) {
        guard let data = try? JSONEncoder().encode(response),
              let jsonString = String(data: data, encoding: .utf8) else {
            print("❌ Failed to encode permission response")
            return
        }

        // Reset state immediately — user made a decision, UI should unblock
        // regardless of whether the WebSocket send succeeds
        self.pendingPermission = nil
        self.outputState = .idle
        self.handleInputBarResolved()

        let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(wsMessage) { error in
            if let error = error {
                print("❌ Failed to send permission response: \(error)")
            } else {
                print("✅ Permission response sent")
            }
        }
    }

    // MARK: - Input bar state transitions

    func handleInputBarPermission(_ request: PermissionRequest) {
        if request.promptType == .question {
            inputBarMode = .questionPrompt(request)
        } else {
            inputBarMode = .permissionPrompt(request)
        }
    }

    func handleInputBarResolved() {
        inputBarMode = .normal
    }

    func handleInputBarDisconnected() {
        inputBarMode = .disconnected
    }

    func handleInputBarSyncing() {
        inputBarMode = .syncing
    }

    func handleInputBarSynced() {
        inputBarMode = .normal
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                self.logToFile("📬 receiveMessage: got message")
                self.handleMessage(message)
                self.receiveMessage()

            case .failure(let error):
                // Don't set error state if we intentionally disconnected
                if case .disconnected = self.connectionState {
                    return
                }
                print("WebSocket receive error: \(error.localizedDescription)")
                self.logToFile("❌ WebSocket receive error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.connectionState = .error(error.localizedDescription)
                }
            }
        }
    }

    func logToFile(_ message: String) {
        let logFile = "/tmp/websocket_debug.log"
        let timestamp = Date().timeIntervalSince1970
        let logMessage = "\(timestamp): \(message)\n"

        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile) {
                if let fileHandle = FileHandle(forWritingAtPath: logFile) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logFile))
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            print("📥 RECEIVED STRING MESSAGE: \(text.prefix(200))...")
            logToFile("📥 STRING: \(text.prefix(200))")
            guard let data = text.data(using: .utf8) else {
                print("❌ Failed to convert string to data")
                logToFile("❌ Failed to convert string to data")
                return
            }

            // Try to decode as AssistantResponseMessage FIRST (before status/audio)
            if let assistantResponse = try? JSONDecoder().decode(AssistantResponseMessage.self, from: data) {
                logToFile("✅ Decoded as AssistantResponseMessage")
                handleAssistantResponse(assistantResponse)
            } else if let statusMessage = try? JSONDecoder().decode(StatusMessage.self, from: data) {
                logToFile("✅ Decoded as StatusMessage: \(statusMessage.state)")
                handleStatusMessage(statusMessage)
            } else if let stopAudio = try? JSONDecoder().decode(StopAudioMessage.self, from: data),
                      stopAudio.type == "stop_audio" {
                logToFile("🛑 Decoded as StopAudio")
                DispatchQueue.main.async {
                    self.onStopAudio?()
                }
            } else if let audioChunk = try? JSONDecoder().decode(AudioChunkMessage.self, from: data) {
                logToFile("✅ Decoded as AudioChunk: \(audioChunk.chunkIndex + 1)/\(audioChunk.totalChunks)")
                handleAudioChunk(audioChunk)
            } else if let projectsResponse = try? JSONDecoder().decode(ProjectsResponse.self, from: data) {
                logToFile("✅ Decoded as ProjectsResponse: \(projectsResponse.projects.count) projects")
                DispatchQueue.main.async {
                    self.onProjectsReceived?(projectsResponse.projects)
                }
            } else if let sessionsResponse = try? JSONDecoder().decode(SessionsResponse.self, from: data) {
                logToFile("✅ Decoded as SessionsResponse: \(sessionsResponse.sessions.count) sessions")
                DispatchQueue.main.async {
                    self.onSessionsReceived?(sessionsResponse.sessions)
                }
            } else if let historyResponse = try? JSONDecoder().decode(SessionHistoryResponse.self, from: data) {
                logToFile("✅ Decoded as SessionHistoryResponse: \(historyResponse.messages.count) messages")
                DispatchQueue.main.async {
                    self.onSessionHistoryReceived?(historyResponse.messages)
                }
            } else if let actionResponse = try? JSONDecoder().decode(SessionActionResponse.self, from: data) {
                logToFile("✅ Decoded as SessionActionResponse: \(actionResponse.type)")
                DispatchQueue.main.async {
                    self.onSessionActionResult?(actionResponse)
                }
            } else if let connectionStatus = try? JSONDecoder().decode(ConnectionStatus.self, from: data) {
                logToFile("Decoded as ConnectionStatus: connected=\(connectionStatus.connected), session=\(connectionStatus.activeSessionId ?? "none")")
                DispatchQueue.main.async {
                    self.connected = connectionStatus.connected
                    self.activeSessionId = connectionStatus.activeSessionId
                    self.branch = connectionStatus.branch
                    self.onConnectionStatusReceived?(connectionStatus)
                }
            } else if let permissionRequest = try? JSONDecoder().decode(PermissionRequest.self, from: data) {
                logToFile("✅ Decoded as PermissionRequest: \(permissionRequest.requestId)")
                DispatchQueue.main.async {
                    self.pendingPermission = permissionRequest
                    self.handleInputBarPermission(permissionRequest)
                    self.onPermissionRequest?(permissionRequest)
                }
            } else if let permissionResolved = try? JSONDecoder().decode(PermissionResolved.self, from: data) {
                logToFile("✅ Decoded as PermissionResolved: \(permissionResolved.requestId)")
                DispatchQueue.main.async {
                    self.outputState = .idle
                    self.voiceState = .idle  // Reset voice state when permission resolved
                    // Always clear pending permission — the terminal may resolve with
                    // a different request_id than what the app has tracked
                    self.pendingPermission = nil
                    self.handleInputBarResolved()
                    self.onPermissionResolved?(permissionResolved)
                }
            } else if let directoryListing = try? JSONDecoder().decode(DirectoryListingResponse.self, from: data),
                      directoryListing.type == "directory_listing" {
                logToFile("Decoded as DirectoryListingResponse: \(directoryListing.path)")
                DispatchQueue.main.async {
                    self.onDirectoryListing?(directoryListing)
                }
            } else if let fileContents = try? JSONDecoder().decode(FileContentsResponse.self, from: data),
                      fileContents.type == "file_contents" {
                logToFile("Decoded as FileContentsResponse: \(fileContents.path)")
                DispatchQueue.main.async {
                    self.onFileContents?(fileContents)
                }
            } else if let contextStats = try? JSONDecoder().decode(ContextStats.self, from: data),
                      contextStats.type == "context_update" {
                logToFile("Decoded as ContextStats: \(contextStats.contextPercentage)%")
                DispatchQueue.main.async {
                    self.contextStats = contextStats
                    self.onContextUpdate?(contextStats)
                }
            } else if let usageStats = try? JSONDecoder().decode(UsageStats.self, from: data),
                      usageStats.type == "usage_response" {
                logToFile("Decoded as UsageStats: session=\(usageStats.session.percentage ?? -1)%")
                DispatchQueue.main.async {
                    self.usageStats = usageStats
                    self.isLoadingUsage = false
                    self.onUsageUpdate?(usageStats)
                }
            } else if let activityStatus = try? JSONDecoder().decode(ActivityStatusMessage.self, from: data),
                      activityStatus.type == "activity_status" {
                logToFile("✅ Decoded as ActivityStatus: \(activityStatus.state)")
                DispatchQueue.main.async {
                    self.activityState = activityStatus
                    self.onActivityStatus?(activityStatus)
                }
            } else if let userMessage = try? JSONDecoder().decode(UserMessage.self, from: data),
                      userMessage.type == "user_message" {
                logToFile("✅ Decoded as UserMessage: \(userMessage.content.prefix(50)) (seq=\(userMessage.seq ?? -1))")
                DispatchQueue.main.async {
                    if let seq = userMessage.seq, seq >= self.lastReceivedSeq {
                        self.lastReceivedSeq = seq
                    }
                    if let messageBranch = userMessage.branch, !messageBranch.isEmpty {
                        self.branch = messageBranch
                    }
                    self.onUserMessage?(userMessage)
                }
            } else if let resyncResponse = try? JSONDecoder().decode(ResyncResponse.self, from: data),
                      resyncResponse.type == "resync_response" {
                logToFile("✅ Decoded as ResyncResponse: \(resyncResponse.messages.count) messages from seq \(resyncResponse.fromSeq)")
                DispatchQueue.main.async {
                    self.onResyncReceived?(resyncResponse)
                }
            } else {
                print("❌ Failed to decode message as any known type")
                print("   Raw data: \(String(data: data, encoding: .utf8) ?? "N/A")")
                logToFile("❌ Failed to decode: \(String(data: data, encoding: .utf8) ?? "N/A")")
            }

        case .data(let data):
            print("📥 RECEIVED BINARY MESSAGE: \(data.count) bytes")
            logToFile("📥 BINARY: \(data.count) bytes")
            // Try AssistantResponseMessage first for binary too
            if let assistantResponse = try? JSONDecoder().decode(AssistantResponseMessage.self, from: data) {
                handleAssistantResponse(assistantResponse)
            } else if let statusMessage = try? JSONDecoder().decode(StatusMessage.self, from: data) {
                handleStatusMessage(statusMessage)
            } else if let audioChunk = try? JSONDecoder().decode(AudioChunkMessage.self, from: data) {
                handleAudioChunk(audioChunk)
            } else if let projectsResponse = try? JSONDecoder().decode(ProjectsResponse.self, from: data) {
                DispatchQueue.main.async {
                    self.onProjectsReceived?(projectsResponse.projects)
                }
            } else if let sessionsResponse = try? JSONDecoder().decode(SessionsResponse.self, from: data) {
                DispatchQueue.main.async {
                    self.onSessionsReceived?(sessionsResponse.sessions)
                }
            } else if let historyResponse = try? JSONDecoder().decode(SessionHistoryResponse.self, from: data) {
                DispatchQueue.main.async {
                    self.onSessionHistoryReceived?(historyResponse.messages)
                }
            } else if let actionResponse = try? JSONDecoder().decode(SessionActionResponse.self, from: data) {
                DispatchQueue.main.async {
                    self.onSessionActionResult?(actionResponse)
                }
            } else if let connectionStatus = try? JSONDecoder().decode(ConnectionStatus.self, from: data) {
                DispatchQueue.main.async {
                    self.connected = connectionStatus.connected
                    self.activeSessionId = connectionStatus.activeSessionId
                    self.branch = connectionStatus.branch
                    self.onConnectionStatusReceived?(connectionStatus)
                }
            } else if let permissionRequest = try? JSONDecoder().decode(PermissionRequest.self, from: data) {
                DispatchQueue.main.async {
                    self.pendingPermission = permissionRequest
                    self.handleInputBarPermission(permissionRequest)
                    self.onPermissionRequest?(permissionRequest)
                }
            } else if let permissionResolved = try? JSONDecoder().decode(PermissionResolved.self, from: data) {
                DispatchQueue.main.async {
                    self.outputState = .idle
                    self.voiceState = .idle  // Reset voice state when permission resolved
                    self.pendingPermission = nil
                    self.handleInputBarResolved()
                    self.onPermissionResolved?(permissionResolved)
                }
            } else {
                print("❌ Failed to decode binary message")
                logToFile("❌ Failed to decode binary message")
            }

        @unknown default:
            break
        }
    }

    private func handleStatusMessage(_ message: StatusMessage) {
        print("📩 RECEIVED STATUS: \(message.state)")
        logToFile("📩 STATUS: \(message.state)")
        // @Published properties must update on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let newState = VoiceState(rawValue: message.state) ?? .idle

            // Always reset outputState when server says idle — server idle means
            // Claude is done, so any stale permission/tool state should clear.
            // This is decoupled from audio playback (audio is cosmetic, not blocking).
            if newState == .idle && self.outputState != .idle {
                print("🔄 RESETTING outputState to idle")
                self.logToFile("🔄 outputState -> idle")
                self.outputState = .idle
            }

            // Don't override voiceState to idle if audio is still playing
            // (keeps the "speaking" indicator accurate, but doesn't block interaction)
            if newState == .idle && self.isPlayingAudio {
                print("🚫 Keeping voiceState=speaking - audio still playing")
                self.logToFile("🚫 voiceState stays speaking - audio playing")
                return
            }

            // Only update if value actually changed to avoid SwiftUI render loops
            if self.voiceState != newState {
                print("🔄 UPDATING voiceState to: \(newState.description)")
                self.logToFile("🔄 voiceState -> \(newState.description)")
                self.voiceState = newState
            }
        }
        onStatusUpdate?(message)
    }

    private func handleAudioChunk(_ chunk: AudioChunkMessage) {
        print("🎵 RECEIVED AUDIO CHUNK: \(chunk.chunkIndex + 1)/\(chunk.totalChunks)")
        onAudioChunk?(chunk)
    }

    private func handleAssistantResponse(_ message: AssistantResponseMessage) {
        print("📦 RECEIVED ASSISTANT RESPONSE: \(message.contentBlocks.count) blocks (seq=\(message.seq ?? -1))")
        logToFile("📦 ASSISTANT RESPONSE: \(message.contentBlocks.count) blocks (seq=\(message.seq ?? -1))")

        // Track sequence number for gap detection
        if let seq = message.seq, seq >= lastReceivedSeq {
            DispatchQueue.main.async { self.lastReceivedSeq = seq }
        }

        // Update branch if provided
        if let messageBranch = message.branch, !messageBranch.isEmpty {
            DispatchQueue.main.async { self.branch = messageBranch }
        }

        // Store content blocks
        lastContentBlocks = message.contentBlocks

        // Log block types for debugging and update output state
        for (index, block) in message.contentBlocks.enumerated() {
            switch block {
            case .text(let textBlock):
                print("  Block \(index): text - \(textBlock.text.prefix(50))...")
                logToFile("  Block \(index): text")
            case .thinking(let thinkingBlock):
                print("  Block \(index): thinking - \(thinkingBlock.thinking.prefix(50))...")
                logToFile("  Block \(index): thinking")
                DispatchQueue.main.async { self.outputState = .thinking }
            case .toolUse(let toolBlock):
                print("  Block \(index): tool_use - \(toolBlock.name)")
                logToFile("  Block \(index): tool_use - \(toolBlock.name)")
                DispatchQueue.main.async { self.outputState = .usingTool(toolBlock.name) }
            case .toolResult(let resultBlock):
                print("  Block \(index): tool_result - \(resultBlock.toolUseId)")
                logToFile("  Block \(index): tool_result - \(resultBlock.toolUseId)")
            case .unknown:
                print("  Block \(index): unknown type (skipped)")
                logToFile("  Block \(index): unknown type")
            }
        }

        // Notify callback (for future UI)
        onAssistantResponse?(message)
    }

    private func attemptReconnect() {
        guard shouldReconnect, reconnectAttempts < maxReconnectAttempts else {
            connectionState = .disconnected
            return
        }

        // Validate URLSession is still valid before attempting reconnect
        guard urlSession != nil else {
            connectionState = .error("Cannot reconnect: URLSession invalidated")
            shouldReconnect = false
            return
        }

        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 30.0)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.shouldReconnect else { return }

            // Double-check URLSession is still valid after delay
            guard self.urlSession != nil else {
                self.connectionState = .error("Cannot reconnect: URLSession invalidated")
                self.shouldReconnect = false
                return
            }

            guard let url = self.currentURL else {
                self.connectionState = .error("Cannot reconnect: no previous connection")
                return
            }

            self.connectToURL(url)
        }
    }
}

extension WebSocketManager: URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ WEBSOCKET CONNECTED")
        // Already on main thread due to delegateQueue: .main
        connectionState = .connected
        outputState = .idle  // Reset output state on new connection
        activityState = nil
        reconnectAttempts = 0
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // Already on main thread due to delegateQueue: .main
        connectionState = .disconnected
        handleInputBarDisconnected()

        if shouldReconnect {
            attemptReconnect()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        // Don't set error state if we intentionally disconnected
        if case .disconnected = connectionState { return }
        print("❌ WEBSOCKET CONNECTION FAILED: \(error.localizedDescription)")
        connectionState = .error("Connection failed")
        handleInputBarDisconnected()
        shouldReconnect = false
    }
}
