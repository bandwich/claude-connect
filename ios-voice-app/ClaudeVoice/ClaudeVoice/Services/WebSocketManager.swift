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
    @Published var outputState: ClaudeOutputState = .idle {
        didSet {
            print("🔄 outputState didSet: \(oldValue) -> \(outputState)")
        }
    }

    var onAudioChunk: ((AudioChunkMessage) -> Void)?
    var onStatusUpdate: ((StatusMessage) -> Void)?
    var onAssistantResponse: ((AssistantResponseMessage) -> Void)?  // NEW
    var onProjectsReceived: (([Project]) -> Void)?
    var onSessionsReceived: (([Session]) -> Void)?
    var onSessionHistoryReceived: (([SessionHistoryMessage]) -> Void)?
    var onSessionActionResult: ((SessionActionResponse) -> Void)?
    var onConnectionStatusReceived: ((ConnectionStatus) -> Void)?
    var onPermissionRequest: ((PermissionRequest) -> Void)?
    var onPermissionResolved: ((PermissionResolved) -> Void)?
    var onDirectoryListing: ((DirectoryListingResponse) -> Void)?
    var onFileContents: ((FileContentsResponse) -> Void)?
    @Published var pendingPermission: PermissionRequest? = nil {
        didSet {
            print("🔄 pendingPermission didSet: \(oldValue?.requestId ?? "nil") -> \(pendingPermission?.requestId ?? "nil")")
        }
    }
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
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        currentURL = nil
        connectedURL = nil

        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.voiceState = .idle
        }
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
        webSocketTask?.send(wsMessage) { error in
            if let error = error {
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

        let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(wsMessage) { error in
            if let error = error {
                print("❌ Failed to send permission response: \(error)")
            } else {
                print("✅ Permission response sent")
                DispatchQueue.main.async {
                    self.pendingPermission = nil
                    self.outputState = .idle  // Reset state after responding
                }
            }
        }
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
                print("WebSocket receive error: \(error.localizedDescription)")
                self.logToFile("❌ WebSocket receive error: \(error.localizedDescription)")
                self.connectionState = .error(error.localizedDescription)
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
                    self.onConnectionStatusReceived?(connectionStatus)
                }
            } else if let permissionRequest = try? JSONDecoder().decode(PermissionRequest.self, from: data) {
                logToFile("✅ Decoded as PermissionRequest: \(permissionRequest.requestId)")
                DispatchQueue.main.async {
                    self.outputState = .awaitingPermission(permissionRequest.requestId)
                    self.pendingPermission = permissionRequest
                    self.onPermissionRequest?(permissionRequest)
                }
            } else if let permissionResolved = try? JSONDecoder().decode(PermissionResolved.self, from: data) {
                logToFile("✅ Decoded as PermissionResolved: \(permissionResolved.requestId)")
                DispatchQueue.main.async {
                    self.outputState = .idle
                    self.voiceState = .idle  // Reset voice state when permission resolved
                    if self.pendingPermission?.requestId == permissionResolved.requestId {
                        self.pendingPermission = nil
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
                    self.onConnectionStatusReceived?(connectionStatus)
                }
            } else if let permissionRequest = try? JSONDecoder().decode(PermissionRequest.self, from: data) {
                DispatchQueue.main.async {
                    self.outputState = .awaitingPermission(permissionRequest.requestId)
                    self.pendingPermission = permissionRequest
                    self.onPermissionRequest?(permissionRequest)
                }
            } else if let permissionResolved = try? JSONDecoder().decode(PermissionResolved.self, from: data) {
                DispatchQueue.main.async {
                    self.outputState = .idle
                    self.voiceState = .idle  // Reset voice state when permission resolved
                    if self.pendingPermission?.requestId == permissionResolved.requestId {
                        self.pendingPermission = nil
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

            // Don't override to idle if audio is currently playing
            if newState == .idle && self.isPlayingAudio {
                print("🚫 Ignoring idle status - audio still playing")
                self.logToFile("🚫 Ignoring idle - audio playing")
                return
            }

            // Only update if value actually changed to avoid SwiftUI render loops
            if self.voiceState != newState {
                print("🔄 UPDATING voiceState to: \(newState.description)")
                self.logToFile("🔄 voiceState -> \(newState.description)")
                self.voiceState = newState
            }

            // Also reset outputState when server says we're idle
            // Server sends "idle" after connection and after TTS completes
            // This ensures outputState doesn't get stuck at .thinking/.usingTool
            if newState == .idle && !self.outputState.expectsPermissionResponse && self.outputState != .idle {
                print("🔄 RESETTING outputState to idle")
                self.logToFile("🔄 outputState -> idle")
                self.outputState = .idle
            }
        }
        onStatusUpdate?(message)
    }

    private func handleAudioChunk(_ chunk: AudioChunkMessage) {
        print("🎵 RECEIVED AUDIO CHUNK: \(chunk.chunkIndex + 1)/\(chunk.totalChunks)")
        onAudioChunk?(chunk)
    }

    private func handleAssistantResponse(_ message: AssistantResponseMessage) {
        print("📦 RECEIVED ASSISTANT RESPONSE: \(message.contentBlocks.count) blocks")
        logToFile("📦 ASSISTANT RESPONSE: \(message.contentBlocks.count) blocks")

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
        reconnectAttempts = 0
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // Already on main thread due to delegateQueue: .main
        connectionState = .disconnected

        if shouldReconnect {
            attemptReconnect()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Called when connection fails (host unreachable, refused, timeout, etc.)
        guard let error = error else { return }
        print("❌ WEBSOCKET CONNECTION FAILED: \(error.localizedDescription)")
        // Already on main thread due to delegateQueue: .main
        connectionState = .error("Connection failed")
        shouldReconnect = false
    }
}
