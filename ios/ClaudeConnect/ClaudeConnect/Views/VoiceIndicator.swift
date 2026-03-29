import SwiftUI

struct VoiceIndicator: View {
    let state: VoiceState
    @State private var animationAmount: CGFloat = 1.0

    var body: some View {
        ZStack {
            Circle()
                .fill(stateColor)
                .frame(width: 120, height: 120)
                .scaleEffect(animationAmount)
                .opacity(0.6)

            Circle()
                .fill(stateColor)
                .frame(width: 100, height: 100)

            Image(systemName: stateIcon)
                .font(.system(size: 40))
                .foregroundColor(.white)
        }
        .onAppear {
            if shouldAnimate {
                withAnimation(Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    animationAmount = 1.2
                }
            }
        }
        .onChange(of: state) { newState in
            if shouldAnimate {
                withAnimation(Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    animationAmount = 1.2
                }
            } else {
                withAnimation {
                    animationAmount = 1.0
                }
            }
        }
    }

    private var stateColor: Color {
        switch state {
        case .idle:
            return .gray
        case .listening:
            return .blue
        case .processing:
            return .yellow
        case .speaking:
            return .green
        }
    }

    private var stateIcon: String {
        switch state {
        case .idle:
            return "mic.slash"
        case .listening:
            return "mic.fill"
        case .processing:
            return "brain"
        case .speaking:
            return "speaker.wave.3.fill"
        }
    }

    private var shouldAnimate: Bool {
        switch state {
        case .listening, .processing, .speaking:
            return true
        case .idle:
            return false
        }
    }
}

#Preview {
    VStack(spacing: 40) {
        VoiceIndicator(state: .idle)
        VoiceIndicator(state: .listening)
        VoiceIndicator(state: .processing)
        VoiceIndicator(state: .speaking)
    }
}
