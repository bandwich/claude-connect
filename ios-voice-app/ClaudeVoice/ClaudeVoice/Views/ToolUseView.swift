import SwiftUI

struct ToolUseView: View {
    let tool: ToolUseBlock
    let result: ToolResultBlock?
    @State private var isExpanded = false

    private let maxPreviewLines = 20

    private var isTaskOutput: Bool {
        tool.name == "TaskOutput"
    }

    private var shouldHideResult: Bool {
        ["Task", "Read", "Edit", "Grep", "Glob"].contains(tool.name)
    }

    /// Tools where results are collapsed by default but expandable
    private var shouldCollapseResult: Bool {
        tool.name == "Bash"
    }

    /// Whether the result content has more lines than maxPreviewLines
    private var resultHasTruncatableContent: Bool {
        guard !shouldHideResult && !shouldCollapseResult else { return false }
        guard let result = result else { return false }
        let content = displayContent(for: result)
        return content.components(separatedBy: "\n").count > maxPreviewLines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: icon + tool name + chevron for expand/collapse
            HStack(spacing: 6) {
                Image(systemName: toolIcon)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(tool.name)
                    .font(.caption.bold())
                    .foregroundColor(.secondary)

                if !shouldCollapseResult && resultHasTruncatableContent {
                    Spacer()
                    Button {
                        withAnimation { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
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
            if shouldHideResult {
                if result != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("Done")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Running...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                }
            } else if shouldCollapseResult {
                if let result = result {
                    collapsedResultView(result)
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Running...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                }
            } else if let result = result {
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

    /// Extract display content from tool result, parsing <output> tags for TaskOutput
    private func displayContent(for result: ToolResultBlock) -> String {
        if isTaskOutput {
            return extractOutputContent(from: result.content)
        }
        return result.content
    }

    /// Extract content between <output> and </output> tags
    private func extractOutputContent(from content: String) -> String {
        guard let startRange = content.range(of: "<output>") else {
            return content
        }
        let afterStart = content[startRange.upperBound...]
        if let endRange = afterStart.range(of: "</output>") {
            let extracted = String(afterStart[..<endRange.lowerBound])
            // Trim leading/trailing newlines from the extracted content
            return extracted.trimmingCharacters(in: .newlines)
        }
        // No closing tag - return everything after <output>
        return String(afterStart).trimmingCharacters(in: .newlines)
    }

    @ViewBuilder
    private func collapsedResultView(_ result: ToolResultBlock) -> some View {
        let isError = result.isError == true
        if isExpanded {
            VStack(alignment: .leading, spacing: 4) {
                let content = displayContent(for: result)
                Text(content.isEmpty ? "(empty)" : content)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(isError ? .red : .primary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isError ? Color.red.opacity(0.1) : Color(.systemGray6))
                    .cornerRadius(6)

                Button {
                    withAnimation { isExpanded = false }
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "chevron.up")
                            .font(.caption2)
                        Text("Hide output")
                            .font(.caption2)
                        Spacer()
                    }
                    .foregroundColor(.accentColor)
                    .padding(.top, 2)
                }
            }
        } else {
            Button {
                withAnimation { isExpanded = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isError ? "xmark.circle" : "checkmark")
                        .font(.caption2)
                        .foregroundColor(isError ? .red : .secondary)
                    Text(isError ? "Error — tap to show" : "Done — tap to show output")
                        .font(.caption2)
                        .foregroundColor(isError ? .red : .secondary)
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func resultView(_ result: ToolResultBlock) -> some View {
        let content = displayContent(for: result)
        let lines = content.components(separatedBy: "\n")
        let needsTruncation = lines.count > maxPreviewLines
        let showTruncated = needsTruncation && !isExpanded
        let displayLines = showTruncated ? Array(lines.prefix(maxPreviewLines)) : lines
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
                if !isExpanded {
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
                } else {
                    Button {
                        withAnimation { isExpanded = false }
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "chevron.up")
                                .font(.caption2)
                            Text("Hide")
                                .font(.caption2)
                            Spacer()
                        }
                        .foregroundColor(.accentColor)
                        .padding(.top, 2)
                    }
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
        case "TaskOutput": return "arrow.triangle.branch"
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
            guard let path = stringInput("file_path") else { return nil }
            let filename = (path as NSString).lastPathComponent
            if let offset = tool.input["offset"]?.value as? Int,
               let limit = tool.input["limit"]?.value as? Int {
                return "\(filename):\(offset)-\(offset + limit - 1)"
            } else if let offset = tool.input["offset"]?.value as? Int {
                return "\(filename):\(offset)+"
            }
            return filename
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
            let agentType = stringInput("subagent_type") ?? "Agent"
            let desc = stringInput("description") ?? ""
            return desc.isEmpty ? agentType : "\(agentType): \(desc)"
        case "TaskOutput":
            return stringInput("task_id")
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
