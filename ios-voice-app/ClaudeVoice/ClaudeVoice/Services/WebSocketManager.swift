import Foundation
import Combine

class WebSocketManager: NSObject, ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected

    @Published var voiceState: VoiceState = .idle {
        didSet {
            logToFile("🔄 voiceState didSet: \(oldValue.description) -> \(voiceState.description)")
            print("🔄 voiceState didSet: \(oldValue.description) -> \(voiceState.description)")
        }
    }

    var onAudioChunk: ((AudioChunkMessage) -> Void)?
    var onStatusUpdate: ((StatusMessage) -> Void)?
    var isPlayingAudio: Bool = false // Tracks if audio is currently playing

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var currentURL: URL?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var shouldReconnect = false

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        // Increase timeout to handle long TTS generation (can take 20+ seconds for long responses)
        // Plus streaming time (10+ seconds for large audio chunks)
        config.timeoutIntervalForRequest = 120  // 2 minutes
        config.timeoutIntervalForResource = 120  // 2 minutes
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
                // Already on main thread
                self.connectionState = .error(error.localizedDescription)
                self.attemptReconnect()
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

            if let statusMessage = try? JSONDecoder().decode(StatusMessage.self, from: data) {
                logToFile("✅ Decoded as StatusMessage: \(statusMessage.state)")
                handleStatusMessage(statusMessage)
            } else if let audioChunk = try? JSONDecoder().decode(AudioChunkMessage.self, from: data) {
                logToFile("✅ Decoded as AudioChunk: \(audioChunk.chunkIndex + 1)/\(audioChunk.totalChunks)")
                handleAudioChunk(audioChunk)
            } else {
                print("❌ Failed to decode message as StatusMessage or AudioChunkMessage")
                print("   Raw data: \(String(data: data, encoding: .utf8) ?? "N/A")")
                logToFile("❌ Failed to decode: \(String(data: data, encoding: .utf8) ?? "N/A")")
            }

        case .data(let data):
            print("📥 RECEIVED BINARY MESSAGE: \(data.count) bytes")
            logToFile("📥 BINARY: \(data.count) bytes")
            if let statusMessage = try? JSONDecoder().decode(StatusMessage.self, from: data) {
                handleStatusMessage(statusMessage)
            } else if let audioChunk = try? JSONDecoder().decode(AudioChunkMessage.self, from: data) {
                handleAudioChunk(audioChunk)
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

            print("🔄 UPDATING voiceState to: \(newState.description)")
            self.logToFile("🔄 voiceState -> \(newState.description)")
            self.voiceState = newState
        }
        onStatusUpdate?(message)
    }

    private func handleAudioChunk(_ chunk: AudioChunkMessage) {
        print("🎵 RECEIVED AUDIO CHUNK: \(chunk.chunkIndex + 1)/\(chunk.totalChunks)")
        onAudioChunk?(chunk)
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

extension WebSocketManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ WEBSOCKET CONNECTED")
        // Already on main thread due to delegateQueue: .main
        connectionState = .connected
        reconnectAttempts = 0
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // Already on main thread due to delegateQueue: .main
        connectionState = .disconnected

        if shouldReconnect {
            attemptReconnect()
        }
    }
}
