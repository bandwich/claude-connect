import Foundation
import Combine
import Network

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
    @Published var activeSessionIds: [String] = []
    @Published var unreadSessionIds: Set<String> = []
    var currentlyViewingSessionId: String?  // Set by SessionView onAppear/onDisappear
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
    var onSessionHistoryReceived: (([SessionHistoryMessageRich], Int?) -> Void)?
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
    var onDeliveryStatus: ((DeliveryStatusMessage) -> Void)?
    var onTaskCompleted: ((String) -> Void)?  // tool_use_id
    var onSessionCleared: ((String) -> Void)?  // new session ID
    var onCommandResponse: ((String, String) -> Void)?  // (command, output)
    @Published var pendingPermission: PermissionRequest? = nil {
        didSet {
            print("🔄 pendingPermission didSet: \(oldValue?.requestId ?? "nil") -> \(pendingPermission?.requestId ?? "nil")")
        }
    }
    @Published var contextStats: ContextStats? = nil
    @Published var usageStats: UsageStats? = nil
    @Published var inputBarMode: InputBarMode = .normal
    @Published var availableCommands: [SlashCommand] = []
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
    var isReconnecting = false
    private(set) var foregroundMaxRetries = 3
    @Published var connectedURL: String? = nil

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        // Request timeout - time allowed between data packets (including WebSocket pings).
        // Server pings every 30s, so this must exceed that interval.
        config.timeoutIntervalForRequest = 90  // 90 seconds (3x server ping interval)
        // Resource timeout - 0 = unlimited, required for long-lived WebSocket connections
        config.timeoutIntervalForResource = 0
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
        connectedURL = url.absoluteString
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

        // Pre-check — fail fast if server is unreachable
        // Tailscale CGNAT IPs use HTTP probe (NWConnection doesn't route through VPN)
        // Local IPs use TCP probe (faster, no VPN issues)
        if let host = url.host, let port = url.port {
            Task { [weak self] in
                guard let self = self else { return }
                let useTailscaleProbe = isTailscaleIP(host)
                let reachable = useTailscaleProbe
                    ? await self.httpCheck(host: host, port: UInt16(port))
                    : await self.tcpCheck(host: host, port: UInt16(port))
                if !reachable {
                    await MainActor.run {
                        self.connectionState = .error("Server not reachable")
                        self.shouldReconnect = false
                    }
                    return
                }
                // Pre-check succeeded — proceed with WebSocket on main thread
                await MainActor.run {
                    guard self.connectionState == .connecting else { return }
                    let task = self.urlSession?.webSocketTask(with: url)
                    self.webSocketTask = task
                    task?.resume()
                    self.receiveMessage()
                }
            }
        } else {
            // Fallback: no host/port available, connect directly
            webSocketTask = session.webSocketTask(with: url)
            webSocketTask?.resume()
            receiveMessage()
        }
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

    func reconnectIfNeeded() {
        switch connectionState {
        case .connected, .connecting:
            return
        default:
            break
        }

        guard currentURL != nil else { return }

        isReconnecting = true
        shouldReconnect = true
        reconnectAttempts = 0
        connectToURL(currentURL!)
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

    func stopAudio() {
        let message = ["type": "stop_audio"]
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

    func stopSession(sessionId: String) {
        let message: [String: Any] = [
            "type": "stop_session",
            "session_id": sessionId
        ]
        sendJSON(message)
    }

    func viewSession(sessionId: String) {
        let message: [String: Any] = [
            "type": "view_session",
            "session_id": sessionId
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

    func handleDidOpen() {
        connectionState = .connected
        outputState = .idle
        activityState = nil
        reconnectAttempts = 0
        isReconnecting = false
    }

    func sendInterrupt() {
        let message = ["type": "interrupt"]
        sendJSON(message)
        // Reset input bar in case we're interrupting a permission prompt
        pendingPermission = nil
        handleInputBarResolved()
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

    func sendQuestionResponse(_ message: QuestionResponseMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let jsonString = String(data: data, encoding: .utf8) else {
            print("❌ Failed to encode question response")
            return
        }

        let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(wsMessage) { error in
            if let error = error {
                print("❌ Failed to send question response: \(error)")
            } else {
                print("✅ Question response sent")
            }
        }
        logToFile("📤 Sent question_response: \(message.requestId)")
    }

    // MARK: - Input bar state transitions

    func handleInputBarPermission(_ request: PermissionRequest) {
        let oldMode = inputBarMode
        inputBarMode = .permissionPrompt(request)
        logToFile("🔀 inputBarMode: \(oldMode) → \(inputBarMode)")
    }

    func handleInputBarResolved() {
        let oldMode = inputBarMode
        inputBarMode = .normal
        logToFile("🔀 inputBarMode: \(oldMode) → .normal (resolved)")
    }

    func handleInputBarDisconnected() {
        let oldMode = inputBarMode
        inputBarMode = .disconnected
        logToFile("🔀 inputBarMode: \(oldMode) → .disconnected")
    }

    func handleInputBarSyncing() {
        let oldMode = inputBarMode
        inputBarMode = .syncing
        logToFile("🔀 inputBarMode: \(oldMode) → .syncing")
    }

    func handleInputBarSynced() {
        let oldMode = inputBarMode
        inputBarMode = .normal
        logToFile("🔀 inputBarMode: \(oldMode) → .normal (synced)")
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

        // Also send inputBarMode/connectionState transitions to server for debugging
        if message.contains("inputBarMode") || message.contains("connectionState") {
            let safeMessage = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "'")
                .replacingOccurrences(of: "\n", with: " ")
            let debugMsg = "{\"type\":\"debug_log\",\"message\":\"\(safeMessage)\"}"
            webSocketTask?.send(.string(debugMsg)) { _ in }
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
                    if let activeIds = sessionsResponse.activeSessionIds {
                        self.activeSessionIds = activeIds
                    }
                    self.onSessionsReceived?(sessionsResponse.sessions)
                }
            } else if let historyResponse = try? JSONDecoder().decode(SessionHistoryResponse.self, from: data) {
                logToFile("✅ Decoded as SessionHistoryResponse: \(historyResponse.messages.count) messages, lineCount=\(historyResponse.lineCount ?? -1)")
                DispatchQueue.main.async {
                    self.onSessionHistoryReceived?(historyResponse.messages, historyResponse.lineCount)
                }
            } else if let actionResponse = try? JSONDecoder().decode(SessionActionResponse.self, from: data) {
                logToFile("✅ Decoded as SessionActionResponse: \(actionResponse.type)")
                DispatchQueue.main.async {
                    self.onSessionActionResult?(actionResponse)
                }
            } else if let cleared = try? JSONDecoder().decode(SessionClearedMessage.self, from: data),
                      cleared.type == "session_cleared" {
                logToFile("✅ Decoded as SessionClearedMessage: \(cleared.sessionId)")
                DispatchQueue.main.async {
                    self.onSessionCleared?(cleared.sessionId)
                }
            } else if let connectionStatus = try? JSONDecoder().decode(ConnectionStatus.self, from: data) {
                logToFile("Decoded as ConnectionStatus: connected=\(connectionStatus.connected), session=\(connectionStatus.activeSessionId ?? "none")")
                DispatchQueue.main.async {
                    self.connected = connectionStatus.connected

                    self.activeSessionIds = connectionStatus.activeSessionIds ?? []
                    self.branch = connectionStatus.branch
                    self.onConnectionStatusReceived?(connectionStatus)
                }
            } else if let questionPrompt = try? JSONDecoder().decode(QuestionPrompt.self, from: data),
                      questionPrompt.type == "question_prompt" {
                logToFile("✅ Decoded as QuestionPrompt: \(questionPrompt.requestId)")
                DispatchQueue.main.async {
                    if let promptSession = questionPrompt.sessionId,
                       !promptSession.isEmpty,
                       let viewedSession = self.currentlyViewingSessionId,
                       promptSession != viewedSession {
                        self.logToFile("⏭️ Skipping question for non-viewed session: \(promptSession)")
                        return
                    }
                    self.inputBarMode = .questionPrompt(questionPrompt)
                }
            } else if let questionResolved = try? JSONDecoder().decode(QuestionResolved.self, from: data),
                      questionResolved.type == "question_resolved" {
                logToFile("✅ Decoded as QuestionResolved: \(questionResolved.requestId)")
                DispatchQueue.main.async {
                    if case .questionPrompt(let current) = self.inputBarMode,
                       current.requestId == questionResolved.requestId {
                        self.inputBarMode = .normal
                    }
                }
            } else if let commandsList = try? JSONDecoder().decode(CommandsListResponse.self, from: data),
                      commandsList.type == "commands_list" {
                logToFile("✅ Decoded as CommandsListResponse: \(commandsList.commands.count) commands")
                DispatchQueue.main.async {
                    self.availableCommands = commandsList.commands
                }
            } else if let commandResponse = try? JSONDecoder().decode(CommandResponseMessage.self, from: data),
                      commandResponse.type == "command_response" {
                logToFile("✅ Decoded as CommandResponse: \(commandResponse.command)")
                DispatchQueue.main.async {
                    self.onCommandResponse?(commandResponse.command, commandResponse.output)
                }
            } else if let permissionRequest = try? JSONDecoder().decode(PermissionRequest.self, from: data) {
                logToFile("✅ Decoded as PermissionRequest: \(permissionRequest.requestId)")
                DispatchQueue.main.async {
                    if let promptSession = permissionRequest.sessionId,
                       !promptSession.isEmpty,
                       let viewedSession = self.currentlyViewingSessionId,
                       promptSession != viewedSession {
                        self.logToFile("⏭️ Skipping permission for non-viewed session: \(promptSession)")
                        return
                    }
                    self.pendingPermission = permissionRequest
                    self.handleInputBarPermission(permissionRequest)
                    self.onPermissionRequest?(permissionRequest)
                }
            } else if let permissionResolved = try? JSONDecoder().decode(PermissionResolved.self, from: data) {
                logToFile("✅ Decoded as PermissionResolved: \(permissionResolved.requestId)")
                DispatchQueue.main.async {
                    self.outputState = .idle
                    self.voiceState = .idle  // Reset voice state when permission resolved
                    // Only clear if this resolves the currently pending permission —
                    // a new permission_request may have already arrived
                    if self.pendingPermission == nil || self.pendingPermission?.requestId == permissionResolved.requestId {
                        self.pendingPermission = nil
                        self.handleInputBarResolved()
                    }
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
            } else if let deliveryStatus = try? JSONDecoder().decode(DeliveryStatusMessage.self, from: data),
                      deliveryStatus.type == "delivery_status" {
                logToFile("✅ Decoded as DeliveryStatus: \(deliveryStatus.status)")
                DispatchQueue.main.async {
                    self.onDeliveryStatus?(deliveryStatus)
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
            } else if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      dict["type"] as? String == "task_completed",
                      let toolUseId = dict["tool_use_id"] as? String {
                logToFile("✅ Decoded as task_completed: \(toolUseId)")
                DispatchQueue.main.async {
                    self.onTaskCompleted?(toolUseId)
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
                    if let activeIds = sessionsResponse.activeSessionIds {
                        self.activeSessionIds = activeIds
                    }
                    self.onSessionsReceived?(sessionsResponse.sessions)
                }
            } else if let historyResponse = try? JSONDecoder().decode(SessionHistoryResponse.self, from: data) {
                DispatchQueue.main.async {
                    self.onSessionHistoryReceived?(historyResponse.messages, historyResponse.lineCount)
                }
            } else if let actionResponse = try? JSONDecoder().decode(SessionActionResponse.self, from: data) {
                DispatchQueue.main.async {
                    self.onSessionActionResult?(actionResponse)
                }
            } else if let cleared = try? JSONDecoder().decode(SessionClearedMessage.self, from: data),
                      cleared.type == "session_cleared" {
                DispatchQueue.main.async {
                    self.onSessionCleared?(cleared.sessionId)
                }
            } else if let connectionStatus = try? JSONDecoder().decode(ConnectionStatus.self, from: data) {
                DispatchQueue.main.async {
                    self.connected = connectionStatus.connected

                    self.activeSessionIds = connectionStatus.activeSessionIds ?? []
                    self.branch = connectionStatus.branch
                    self.onConnectionStatusReceived?(connectionStatus)
                }
            } else if let questionPrompt = try? JSONDecoder().decode(QuestionPrompt.self, from: data),
                      questionPrompt.type == "question_prompt" {
                logToFile("✅ Decoded as QuestionPrompt: \(questionPrompt.requestId)")
                DispatchQueue.main.async {
                    if let promptSession = questionPrompt.sessionId,
                       !promptSession.isEmpty,
                       let viewedSession = self.currentlyViewingSessionId,
                       promptSession != viewedSession {
                        self.logToFile("⏭️ Skipping question for non-viewed session: \(promptSession)")
                        return
                    }
                    self.inputBarMode = .questionPrompt(questionPrompt)
                }
            } else if let questionResolved = try? JSONDecoder().decode(QuestionResolved.self, from: data),
                      questionResolved.type == "question_resolved" {
                logToFile("✅ Decoded as QuestionResolved: \(questionResolved.requestId)")
                DispatchQueue.main.async {
                    if case .questionPrompt(let current) = self.inputBarMode,
                       current.requestId == questionResolved.requestId {
                        self.inputBarMode = .normal
                    }
                }
            } else if let permissionRequest = try? JSONDecoder().decode(PermissionRequest.self, from: data) {
                DispatchQueue.main.async {
                    if let promptSession = permissionRequest.sessionId,
                       !promptSession.isEmpty,
                       let viewedSession = self.currentlyViewingSessionId,
                       promptSession != viewedSession {
                        self.logToFile("⏭️ Skipping permission for non-viewed session: \(promptSession)")
                        return
                    }
                    self.pendingPermission = permissionRequest
                    self.handleInputBarPermission(permissionRequest)
                    self.onPermissionRequest?(permissionRequest)
                }
            } else if let permissionResolved = try? JSONDecoder().decode(PermissionResolved.self, from: data) {
                DispatchQueue.main.async {
                    self.outputState = .idle
                    self.voiceState = .idle  // Reset voice state when permission resolved
                    if self.pendingPermission == nil || self.pendingPermission?.requestId == permissionResolved.requestId {
                        self.pendingPermission = nil
                        self.handleInputBarResolved()
                    }
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

        // Track unread: if this message is for a session we're not currently on screen, mark it unread
        if let sessionId = message.sessionId, !sessionId.isEmpty,
           sessionId != currentlyViewingSessionId {
            DispatchQueue.main.async { self.unreadSessionIds.insert(sessionId) }
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

    private func isTailscaleIP(_ host: String) -> Bool {
        // Tailscale CGNAT range: 100.64.0.0/10 (100.64.0.0 – 100.127.255.255)
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4, parts[0] == 100 else { return false }
        return parts[1] >= 64 && parts[1] <= 127
    }

    private func httpCheck(host: String, port: UInt16) async -> Bool {
        // HTTP probe for Tailscale IPs — uses URLSession which routes through VPN
        guard let url = URL(string: "http://\(host):\(port)") else { return false }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(from: url)
            // Any response (even error status) means server is reachable
            return (response as? HTTPURLResponse) != nil
        } catch {
            return false
        }
    }

    private func tcpCheck(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            var resumed = false

            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: .global())

            // Safety timeout (5s to allow for Tailscale tunnel setup)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    private func attemptReconnect() {
        let maxAttempts = isReconnecting ? foregroundMaxRetries : maxReconnectAttempts
        guard shouldReconnect, reconnectAttempts < maxAttempts else {
            if isReconnecting {
                connectionState = .error("Server unreachable")
                isReconnecting = false
            } else {
                connectionState = .disconnected
            }
            return
        }

        // Validate URLSession is still valid before attempting reconnect
        guard urlSession != nil else {
            connectionState = .error("Cannot reconnect: URLSession invalidated")
            shouldReconnect = false
            isReconnecting = false
            return
        }

        reconnectAttempts += 1
        let delay = isReconnecting ? 1.0 : min(pow(2.0, Double(reconnectAttempts)), 30.0)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.shouldReconnect else { return }

            // Double-check URLSession is still valid after delay
            guard self.urlSession != nil else {
                self.connectionState = .error("Cannot reconnect: URLSession invalidated")
                self.shouldReconnect = false
                self.isReconnecting = false
                return
            }

            guard let url = self.currentURL else {
                self.connectionState = .error("Cannot reconnect: no previous connection")
                self.isReconnecting = false
                return
            }

            self.connectToURL(url)
        }
    }
}

extension WebSocketManager: URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ WEBSOCKET CONNECTED")
        logToFile("🔌 connectionState: \(connectionState) → .connected (didOpen)")
        // Already on main thread due to delegateQueue: .main
        handleDidOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // Already on main thread due to delegateQueue: .main
        logToFile("🔌 connectionState: \(connectionState) → .disconnected (didClose, code=\(closeCode.rawValue))")
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
        logToFile("🔌 connectionState: \(connectionState) → .error (didComplete, error=\(error.localizedDescription))")
        connectionState = .error("Connection failed")
        handleInputBarDisconnected()
        shouldReconnect = false
    }
}
