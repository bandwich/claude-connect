import Foundation
import AVFoundation

class AudioPlayer: NSObject, ObservableObject {
    @Published var isPlaying = false

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private var expectedChunks = 0
    private var receivedChunks = 0
    private var scheduledChunks = 0
    private let minBufferChunks = 3

    private var audioFormat: AVAudioFormat?

    var onPlaybackStarted: (() -> Void)?
    var onPlaybackFinished: (() -> Void)?

    override init() {
        super.init()
        setupAudioEngine()
        // Don't set up audio session during UI tests
        if !isRunningUITests {
            setupAudioSession()
        }
    }

    private var isRunningUITests: Bool {
        // Check if running under test environment
        return NSClassFromString("XCTestCase") != nil
    }

    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
            try audioSession.setActive(true)
        } catch {
            print("Failed to set up audio session: \(error.localizedDescription)")
        }
    }

    private func setupAudioEngine() {
        // Attach player node to engine
        audioEngine.attach(playerNode)

        // Use float32 format (standard for AVAudioEngine)
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        audioFormat = format

        // Connect player node to output with float32 format
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        audioEngine.prepare()

        // Start the engine now so we can schedule buffers immediately
        do {
            try audioEngine.start()
            print("AudioPlayer: Engine started and ready")
            logToFile("🎛 AudioPlayer: Engine started")
        } catch {
            print("AudioPlayer: Failed to start engine: \(error.localizedDescription)")
            logToFile("❌ Failed to start engine: \(error.localizedDescription)")
        }
    }

    func receiveAudioChunk(_ chunk: AudioChunkMessage) {
        guard let chunkData = Data(base64Encoded: chunk.data) else {
            print("AudioPlayer: Failed to decode base64 audio data")
            logToFile("❌ AudioPlayer: Failed to decode base64")
            return
        }

        receivedChunks += 1
        expectedChunks = chunk.totalChunks

        print("AudioPlayer: Received chunk \(chunk.chunkIndex + 1)/\(chunk.totalChunks)")
        logToFile("🎵 AudioPlayer: Chunk \(chunk.chunkIndex + 1)/\(chunk.totalChunks)")

        // Extract WAV header from first chunk to get audio format
        if chunk.chunkIndex == 0 {
            extractAudioFormat(from: chunkData)
        }

        // Convert chunk to audio buffer and schedule it
        if let buffer = createAudioBuffer(from: chunkData, isFirstChunk: chunk.chunkIndex == 0) {
            // Attach completion handler if this is the last chunk we're expecting
            let isLastExpectedChunk = (receivedChunks == expectedChunks)
            scheduleAudioBuffer(buffer, isLastChunk: isLastExpectedChunk)
            scheduledChunks += 1

            print("AudioPlayer: Scheduled chunk \(scheduledChunks), isLast: \(isLastExpectedChunk)")
            logToFile("📦 Scheduled chunk \(scheduledChunks), isLast: \(isLastExpectedChunk)")
        } else {
            print("AudioPlayer: Failed to create buffer for chunk \(chunk.chunkIndex + 1)")
            logToFile("❌ Failed to create buffer for chunk \(chunk.chunkIndex + 1)")
        }

        // Start playback (playerNode.play()) after buffering minimum chunks
        if receivedChunks >= minBufferChunks && !isPlaying {
            startPlayback()
        }
    }

    private func logToFile(_ message: String) {
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

    private func extractAudioFormat(from data: Data) {
        // Parse WAV header to log the format (for debugging)
        guard data.count >= 44 else {
            print("AudioPlayer: First chunk too small (\(data.count) bytes)")
            return
        }

        // WAV header: sample rate at byte 24 (4 bytes), channels at byte 22 (2 bytes)
        let channels = UInt32(data[22]) | (UInt32(data[23]) << 8)
        let sampleRate = Double(UInt32(data[24]) | (UInt32(data[25]) << 8) | (UInt32(data[26]) << 16) | (UInt32(data[27]) << 24))

        print("AudioPlayer: Parsed WAV header - Sample rate: \(sampleRate) Hz, Channels: \(channels)")

        // NOTE: We do NOT update audioFormat here because the player node is already
        // connected to the engine with a specific format. Changing audioFormat would
        // cause a format mismatch when scheduling buffers, leading to crashes.
        // The connection format (24kHz mono) must match the format used for all buffers.
    }

    private func createAudioBuffer(from data: Data, isFirstChunk: Bool) -> AVAudioPCMBuffer? {
        guard let format = audioFormat else { return nil }

        // Skip WAV header (44 bytes) for first chunk, subsequent chunks are pure PCM
        let pcmData = isFirstChunk ? data.dropFirst(44) : data
        guard !pcmData.isEmpty else { return nil }

        // WAV data is 16-bit signed integers, we need to convert to float32
        // Each sample is 2 bytes (16-bit)
        let sampleCount = pcmData.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(sampleCount)) else {
            return nil
        }

        buffer.frameLength = UInt32(sampleCount)

        // Convert 16-bit PCM to float32
        guard let floatChannelData = buffer.floatChannelData else { return nil }
        let floatData = floatChannelData[0]

        pcmData.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
            let int16Ptr = rawPtr.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                // Convert Int16 (-32768 to 32767) to Float (-1.0 to 1.0)
                floatData[i] = Float(int16Ptr[i]) / 32768.0
            }
        }

        return buffer
    }

    private func scheduleAudioBuffer(_ buffer: AVAudioPCMBuffer, isLastChunk: Bool) {
        if isLastChunk {
            // Schedule with completion handler for last chunk
            playerNode.scheduleBuffer(buffer) { [weak self] in
                DispatchQueue.main.async {
                    self?.handlePlaybackFinished()
                }
            }
        } else {
            playerNode.scheduleBuffer(buffer)
        }
    }

    private func startPlayback() {
        guard !isPlaying else { return }

        // Re-activate playback audio session before playing
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
            try audioSession.setActive(true)
            print("AudioPlayer: Audio session activated for playback")
        } catch {
            print("AudioPlayer: Failed to activate audio session: \(error)")
        }

        // Restart audio engine if it's not running
        if !audioEngine.isRunning {
            print("AudioPlayer: Engine not running, restarting...")
            do {
                try audioEngine.start()
                print("AudioPlayer: Engine restarted successfully")
            } catch {
                print("AudioPlayer: Failed to restart engine: \(error)")
                return
            }
        }

        playerNode.play()

        DispatchQueue.main.async {
            self.isPlaying = true
        }

        print("AudioPlayer: Streaming playback started")
        logToFile("🔊 AudioPlayer: Streaming playback started")
        onPlaybackStarted?()
    }

    private func handlePlaybackFinished() {
        print("AudioPlayer: Playback finished")
        logToFile("🏁 AudioPlayer: Playback finished")

        playerNode.stop()

        DispatchQueue.main.async {
            self.isPlaying = false
        }

        receivedChunks = 0
        scheduledChunks = 0
        expectedChunks = 0

        print("AudioPlayer: Calling onPlaybackFinished callback")
        logToFile("🔇 AudioPlayer: onPlaybackFinished callback")

        if onPlaybackFinished == nil {
            print("AudioPlayer: WARNING - onPlaybackFinished callback is nil!")
            logToFile("⚠️ onPlaybackFinished callback is NIL")
        } else {
            print("AudioPlayer: Executing onPlaybackFinished callback")
            onPlaybackFinished?()
            print("AudioPlayer: onPlaybackFinished callback executed")
        }
    }

    func stop() {
        playerNode.stop()

        receivedChunks = 0
        scheduledChunks = 0
        expectedChunks = 0

        DispatchQueue.main.async {
            self.isPlaying = false
        }

        print("AudioPlayer: Stopped")
        logToFile("⏹ AudioPlayer: Stopped")
    }

    func reset() {
        stop()
    }
}
