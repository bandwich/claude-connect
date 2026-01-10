import Foundation
import Speech
import AVFoundation

class SpeechRecognizer: ObservableObject {
    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var isAuthorized = false

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    var onFinalTranscription: ((String) -> Void)?
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: (() -> Void)?

    init() {
        checkAuthorization()
    }

    private var isIntegrationTestMode: Bool {
        ProcessInfo.processInfo.environment["INTEGRATION_TEST_MODE"] == "1"
    }

    func checkAuthorization() {
        // In integration tests, bypass speech authorization (can't be granted via simctl)
        // The test sends voice input via WebSocket, so actual mic auth isn't needed
        if isIntegrationTestMode {
            isAuthorized = true
            return
        }

        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                self.isAuthorized = authStatus == .authorized
            }
        }
    }

    func startRecording() throws {
        print("🎤 SpeechRecognizer: startRecording() called")

        if audioEngine.isRunning {
            print("🎤 SpeechRecognizer: audioEngine already running, stopping first")
            stopRecording()
            return
        }

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            print("❌ SpeechRecognizer: recognizer not available")
            throw RecognitionError.recognizerNotAvailable
        }

        print("🎤 SpeechRecognizer: Starting recognition task...")

        recognitionTask?.cancel()
        recognitionTask = nil

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let recognitionRequest = recognitionRequest else {
            throw RecognitionError.unableToCreateRequest
        }

        recognitionRequest.shouldReportPartialResults = true

        if #available(iOS 13, *) {
            recognitionRequest.requiresOnDeviceRecognition = false
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            var isFinal = false

            if let result = result {
                let text = result.bestTranscription.formattedString
                print("🎤 Recognition result: '\(text)', isFinal=\(result.isFinal)")
                DispatchQueue.main.async {
                    self.transcribedText = text
                }
                isFinal = result.isFinal
            }

            if error != nil || isFinal {
                print("🎤 SpeechRecognizer: error=\(error?.localizedDescription ?? "nil"), isFinal=\(isFinal)")

                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)

                self.recognitionRequest = nil
                self.recognitionTask = nil

                DispatchQueue.main.async {
                    self.isRecording = false
                    self.onRecordingStopped?()

                    print("🎤 SpeechRecognizer: isFinal=\(isFinal), transcribedText='\(self.transcribedText)', isEmpty=\(self.transcribedText.isEmpty)")

                    if isFinal && !self.transcribedText.isEmpty {
                        print("🎤 SpeechRecognizer: ✅ CALLING onFinalTranscription with: '\(self.transcribedText)'")
                        self.onFinalTranscription?(self.transcribedText)
                        self.transcribedText = ""
                    } else {
                        print("🎤 SpeechRecognizer: ❌ NOT calling onFinalTranscription (isFinal=\(isFinal), isEmpty=\(self.transcribedText.isEmpty))")
                    }
                }
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        print("🎤 Audio format: sampleRate=\(recordingFormat.sampleRate), channels=\(recordingFormat.channelCount)")

        var bufferCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            bufferCount += 1
            if bufferCount == 1 || bufferCount % 10 == 0 {
                print("🎤 Audio buffer #\(bufferCount) received, frames=\(buffer.frameLength)")
            }
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        print("✅ Audio engine started successfully")
        print("🎤 Input node: \(inputNode)")
        print("🎤 Audio engine isRunning: \(audioEngine.isRunning)")

        DispatchQueue.main.async {
            self.isRecording = true
            self.transcribedText = ""
            self.onRecordingStarted?()
        }
    }

    func stopRecording() {
        print("🎤 SpeechRecognizer: stopRecording() called")

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // Tell the recognition request to finish processing
        recognitionRequest?.endAudio()

        print("🎤 SpeechRecognizer: endAudio() called, waiting for final result...")

        // Deactivate the recording audio session to allow playback
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("🎤 SpeechRecognizer: Audio session deactivated")
        } catch {
            print("🎤 SpeechRecognizer: Failed to deactivate audio session: \(error)")
        }

        // Update UI state immediately
        DispatchQueue.main.async {
            self.isRecording = false
        }

        // Don't cancel or cleanup - let the recognition task finish naturally
        // and call the callback with isFinal=true, which will trigger onFinalTranscription
    }

    enum RecognitionError: Error {
        case recognizerNotAvailable
        case unableToCreateRequest
    }

    #if DEBUG
    /// Inject mock speech result for testing (bypasses real recognition)
    func injectMockSpeechResult(text: String) {
        // Trigger same code path as real recognition
        DispatchQueue.main.async {
            self.transcribedText = text
            self.isRecording = false
            self.onRecordingStopped?()

            if !text.isEmpty {
                self.onFinalTranscription?(text)
                self.transcribedText = ""
            }
        }
    }
    #endif
}
