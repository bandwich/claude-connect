// ios-voice-app/ClaudeConnect/ClaudeConnect/Views/DiffView.swift
import SwiftUI

enum DiffLineType {
    case added
    case removed
    case unchanged
}

struct DiffLine: Identifiable {
    let id = UUID()
    let type: DiffLineType
    let text: String
    let lineNumber: Int?
}

struct DiffParser {
    /// Simple line-by-line diff algorithm
    static func parse(old: String, new: String) -> [DiffLine] {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")

        var result: [DiffLine] = []
        var oldIndex = 0
        var newIndex = 0

        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex >= oldLines.count {
                // Only new lines left
                result.append(DiffLine(type: .added, text: newLines[newIndex], lineNumber: newIndex + 1))
                newIndex += 1
            } else if newIndex >= newLines.count {
                // Only old lines left
                result.append(DiffLine(type: .removed, text: oldLines[oldIndex], lineNumber: nil))
                oldIndex += 1
            } else if oldLines[oldIndex] == newLines[newIndex] {
                // Lines match
                result.append(DiffLine(type: .unchanged, text: oldLines[oldIndex], lineNumber: newIndex + 1))
                oldIndex += 1
                newIndex += 1
            } else {
                // Lines differ - show removal then addition
                result.append(DiffLine(type: .removed, text: oldLines[oldIndex], lineNumber: nil))
                result.append(DiffLine(type: .added, text: newLines[newIndex], lineNumber: newIndex + 1))
                oldIndex += 1
                newIndex += 1
            }
        }

        return result
    }
}

struct DiffView: View {
    let oldContent: String
    let newContent: String
    let filePath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File path header
            Text(filePath)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))

            // Diff content
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(DiffParser.parse(old: oldContent, new: newContent)) { line in
                        DiffLineView(line: line)
                    }
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .background(Color(.systemBackground))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
    }
}

struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            // Line prefix
            Text(prefix)
                .foregroundColor(prefixColor)
                .frame(width: 16)

            // Line content
            Text(line.text)
                .foregroundColor(textColor)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(backgroundColor)
    }

    private var prefix: String {
        switch line.type {
        case .added: return "+"
        case .removed: return "-"
        case .unchanged: return " "
        }
    }

    private var prefixColor: Color {
        switch line.type {
        case .added: return .green
        case .removed: return .red
        case .unchanged: return .secondary
        }
    }

    private var textColor: Color {
        switch line.type {
        case .added: return .green
        case .removed: return .red
        case .unchanged: return .primary
        }
    }

    private var backgroundColor: Color {
        switch line.type {
        case .added: return Color.green.opacity(0.1)
        case .removed: return Color.red.opacity(0.1)
        case .unchanged: return .clear
        }
    }
}

#Preview {
    DiffView(
        oldContent: "const foo = 1;\nconst bar = 2;",
        newContent: "const foo = 2;\nconst bar = 2;\nconst baz = 3;",
        filePath: "src/utils.ts"
    )
    .padding()
}
