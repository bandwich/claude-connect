import SwiftUI

struct ToolUseView: View {
    let tool: ToolUseBlock
    let result: ToolResultBlock?
    @State private var isExpanded = false

    private let maxPreviewLines = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: icon + tool name
            HStack(spacing: 6) {
                Image(systemName: toolIcon)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(tool.name)
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 4)

            // Tool input
            if let inputSummary = toolInputSummary {
                Text(inputSummary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(isExpanded ? nil : 3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .cornerRadius(6)
                    .padding(.bottom, 4)
            }

            // Tool result
            if let result = result {
                resultView(result)
            } else {
                // Pending result
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Running...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(8)
            }
        }
        .padding(10)
        .background(Color(.systemGray5).opacity(0.5))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func resultView(_ result: ToolResultBlock) -> some View {
        let lines = result.content.components(separatedBy: "\n")
        let needsTruncation = lines.count > maxPreviewLines && !isExpanded
        let displayLines = needsTruncation ? Array(lines.prefix(maxPreviewLines)) : lines
        let displayText = displayLines.joined(separator: "\n")

        VStack(alignment: .leading, spacing: 4) {
            Text(displayText.isEmpty ? "(empty)" : displayText)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(result.isError == true ? .red : .primary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(result.isError == true ? Color.red.opacity(0.1) : Color(.systemGray6))
                .cornerRadius(6)

            if needsTruncation {
                Button {
                    withAnimation { isExpanded = true }
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                        Text("Show \(lines.count - maxPreviewLines) more lines")
                            .font(.caption2)
                        Spacer()
                    }
                    .foregroundColor(.accentColor)
                    .padding(.top, 2)
                }
            }
        }
    }

    private var toolIcon: String {
        switch tool.name {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder.badge.magnifyingglass"
        case "Task": return "arrow.triangle.branch"
        case "WebSearch": return "globe"
        case "WebFetch": return "globe"
        default: return "wrench"
        }
    }

    private var toolInputSummary: String? {
        switch tool.name {
        case "Bash":
            return stringInput("command")
        case "Read":
            return stringInput("file_path")
        case "Edit":
            return stringInput("file_path")
        case "Write":
            return stringInput("file_path")
        case "Grep":
            let pattern = stringInput("pattern") ?? ""
            let path = stringInput("path") ?? ""
            if !path.isEmpty {
                return "\(pattern) in \(path)"
            }
            return pattern.isEmpty ? nil : pattern
        case "Glob":
            return stringInput("pattern")
        case "Task":
            return stringInput("prompt") ?? stringInput("description")
        default:
            for (_, value) in tool.input {
                if let str = value.value as? String, !str.isEmpty {
                    return str.count > 100 ? String(str.prefix(100)) + "..." : str
                }
            }
            return nil
        }
    }

    private func stringInput(_ key: String) -> String? {
        if let value = tool.input[key]?.value as? String, !value.isEmpty {
            return value
        }
        return nil
    }
}
