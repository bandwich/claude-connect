import SwiftUI

struct ContentView: View {
    @StateObject private var webSocketManager = WebSocketManager()
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @StateObject private var audioPlayer = AudioPlayer()

    @State private var showingSettings = false
    @State private var currentTranscript = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 40) {
                Spacer()

                VoiceIndicator(state: webSocketManager.voiceState)

                Text(webSocketManager.voiceState.description)
                    .font(.title2)
                    .fontWeight(.medium)
                    .accessibilityIdentifier("voiceState")

                if !currentTranscript.isEmpty {
                    Text(currentTranscript)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Spacer()

                connectionStatusBar

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
                .padding(.horizontal, 40)
                .disabled(!canRecord)

                if !speechRecognizer.isAuthorized {
                    Text("Microphone permission required")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(.bottom, 40)
            .navigationTitle("Claude Voice")
            .navigationBarItems(trailing: Button(action: {
                showingSettings = true
            }) {
                Image(systemName: "gearshape.fill")
            })
            .sheet(isPresented: $showingSettings) {
                SettingsView(webSocketManager: webSocketManager)
            }
            .onAppear(perform: setupConnections)
        }
    }

    private var connectionStatusBar: some View {
        HStack {
            Circle()
                .fill(connectionStatusColor)
                .frame(width: 8, height: 8)
            Text(webSocketManager.connectionState.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("connectionStatus")
        }
        .padding(.horizontal)
    }

    private var connectionStatusColor: Color {
        switch webSocketManager.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }

    private var buttonColor: Color {
        if !canRecord {
            return .gray
        }
        return speechRecognizer.isRecording ? .red : .blue
    }

    private var canRecord: Bool {
        if case .connected = webSocketManager.connectionState {
            return speechRecognizer.isAuthorized && !audioPlayer.isPlaying
        }
        return false
    }

    private func setupConnections() {
        speechRecognizer.onRecordingStarted = { [weak webSocketManager] in
            DispatchQueue.main.async {
                webSocketManager?.voiceState = .listening
            }
        }

        speechRecognizer.onRecordingStopped = { [weak webSocketManager] in
            DispatchQueue.main.async {
                // Only return to idle if not already processing or speaking
                if webSocketManager?.voiceState == .listening {
                    webSocketManager?.voiceState = .idle
                }
            }
        }

        speechRecognizer.onFinalTranscription = { text in
            print("📱 ContentView: ✅ onFinalTranscription RECEIVED with text: '\(text)'")
            webSocketManager.logToFile("📱 ContentView: onFinalTranscription text='\(text)'")

            currentTranscript = text

            print("📱 ContentView: Calling webSocketManager.sendVoiceInput...")
            webSocketManager.sendVoiceInput(text: text)
            print("📱 ContentView: webSocketManager.sendVoiceInput returned")

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if currentTranscript == text {
                    currentTranscript = ""
                }
            }
        }

        webSocketManager.onAudioChunk = { chunk in
            audioPlayer.receiveAudioChunk(chunk)
        }

        audioPlayer.onPlaybackStarted = { [weak webSocketManager] in
            // Keep voiceState as speaking while audio plays
            print("ContentView: onPlaybackStarted callback received")
            DispatchQueue.main.async {
                print("ContentView: Setting isPlayingAudio=true, voiceState=speaking")
                webSocketManager?.logToFile("📱 ContentView: isPlayingAudio=true")
                webSocketManager?.isPlayingAudio = true
                webSocketManager?.voiceState = .speaking
            }
        }

        audioPlayer.onPlaybackFinished = { [weak webSocketManager] in
            // Return to idle when playback completes
            print("ContentView: onPlaybackFinished callback received")
            DispatchQueue.main.async {
                print("ContentView: Setting isPlayingAudio=false, voiceState=idle")

                if let manager = webSocketManager {
                    manager.logToFile("📱 ContentView: isPlayingAudio=false")
                    manager.isPlayingAudio = false
                    manager.logToFile("📱 ContentView: BEFORE setting voiceState to .idle")
                    manager.voiceState = .idle
                    manager.logToFile("📱 ContentView: AFTER setting voiceState to .idle")
                } else {
                    print("⚠️ ContentView: webSocketManager is NIL in onPlaybackFinished!")
                }
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
                print("Failed to start recording: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    ContentView()
}
