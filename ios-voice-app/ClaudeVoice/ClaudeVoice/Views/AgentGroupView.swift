import SwiftUI

struct AgentGroupView: View {
    let agents: [AgentInfo]

    private var allDone: Bool {
        agents.allSatisfy { $0.isDone }
    }

    private var doneCount: Int {
        agents.filter { $0.isDone }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text(allDone ? "Ran \(agents.count) agents" : "Running \(agents.count) agents...")
                    .font(.footnote.bold())
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 2)

            // Agent list
            ForEach(Array(agents.enumerated()), id: \.offset) { _, agent in
                HStack(spacing: 8) {
                    if agent.isDone {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    }
                    Text(agent.displayDescription)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(Color(.systemGray5).opacity(0.5))
        .cornerRadius(10)
    }
}
