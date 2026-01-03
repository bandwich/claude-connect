// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
import SwiftUI

struct SessionView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @StateObject private var audioPlayer = AudioPlayer()

    let project: Project
    let session: Session

    @State private var messages: [SessionHistoryMessage] = []
    @State private var currentTranscript = ""
    @State private var showingSettings = false
    @State private var isInitialLoad = true
    @State private var isResuming = false

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

                Text(webSocketManager.voiceState.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("voiceState")

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
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button(action: resumeSession) {
                        Image(systemName: "play.fill")
                    }
                    .accessibilityLabel("Resume Session")

                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(webSocketManager: webSocketManager)
        }
        .onAppear(perform: setupView)
    }

    private var buttonColor: Color {
        if !canRecord { return .gray }
        return speechRecognizer.isRecording ? .red : .blue
    }

    private var canRecord: Bool {
        if case .connected = webSocketManager.connectionState {
            return speechRecognizer.isAuthorized
                && !audioPlayer.isPlaying
                && webSocketManager.voiceState != .processing
        }
        return false
    }

    private func setupView() {
        // Load message history
        webSocketManager.onSessionHistoryReceived = { messages in
            self.messages = messages
        }
        webSocketManager.requestSessionHistory(folderName: project.folderName, sessionId: session.id)

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
            }
        }

        audioPlayer.onPlaybackFinished = {
            DispatchQueue.main.async {
                webSocketManager.isPlayingAudio = false
                webSocketManager.voiceState = .idle
            }
        }
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

    private func resumeSession() {
        guard !isResuming else { return }
        isResuming = true

        webSocketManager.onSessionActionResult = { response in
            isResuming = false
            if response.success {
                // Session resumed - voice input is now active for this session
                print("Session resumed successfully")
            } else {
                print("Failed to resume session: \(response.error ?? "Unknown error")")
            }
        }

        webSocketManager.resumeSession(sessionId: session.id)
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

            if message.role == "assistant" {
                Spacer()
            }
        }
    }
}
