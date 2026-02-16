// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionPromptView.swift
import SwiftUI

struct PermissionPromptView: View {
    let request: PermissionRequest
    let onResponse: (PermissionResponse) -> Void

    @State private var textInput: String = ""
    @State private var selectedOption: Int? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Header based on type
                headerView

                Divider()

                // Content based on type
                contentView

                Spacer()

                // Action buttons
                actionButtons
            }
            .padding()
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var headerView: some View {
        switch request.promptType {
        case .bash, .task:
            VStack(alignment: .leading, spacing: 8) {
                Text(request.promptType == .bash ? "Allow command?" : "Allow agent?")
                    .font(.headline)
                if let description = request.toolInput?.description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .write, .edit:
            VStack(alignment: .leading, spacing: 8) {
                Text(request.promptType == .write ? "Create file?" : "Edit file?")
                    .font(.headline)
                if let filePath = request.context?.filePath {
                    Text(filePath)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .question:
            VStack(alignment: .leading, spacing: 8) {
                Text(request.question?.text ?? "Question")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch request.promptType {
        case .bash:
            // Show command in monospace
            if let command = request.toolInput?.command {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(command)
                        .font(.system(.subheadline, design: .monospaced))
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                }
            }

        case .task:
            // Show task description
            if let description = request.toolInput?.description {
                Text(description)
                    .font(.body)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
            }

        case .write, .edit:
            // Show diff view
            if let context = request.context {
                DiffView(
                    oldContent: context.oldContent ?? "",
                    newContent: context.newContent ?? "",
                    filePath: context.filePath ?? "file"
                )
                .frame(maxHeight: 300)
            }

        case .question:
            // Show text input or option picker
            if let options = request.question?.options, !options.isEmpty {
                // Multiple choice
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        Button(action: { selectedOption = index }) {
                            HStack {
                                Image(systemName: selectedOption == index ? "circle.fill" : "circle")
                                    .foregroundColor(selectedOption == index ? .blue : .secondary)
                                Text(option)
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                        }
                    }
                }
            } else {
                // Text input
                TextField("Type something", text: $textInput)
                    .textFieldStyle(.roundedBorder)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch request.promptType {
        case .bash, .task:
            HStack(spacing: 16) {
                Button("Deny") {
                    sendResponse(.deny)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button("Allow") {
                    sendResponse(.allow)
                }
                .buttonStyle(.borderedProminent)
            }

        case .write, .edit:
            HStack(spacing: 16) {
                Button("Reject") {
                    sendResponse(.deny)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button("Approve") {
                    sendResponse(.allow)
                }
                .buttonStyle(.borderedProminent)
            }

        case .question:
            Button("Submit") {
                sendResponse(.allow)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitDisabled)
        }
    }

    private var navigationTitle: String {
        switch request.promptType {
        case .bash: return "Command"
        case .write: return "New File"
        case .edit: return "Edit"
        case .question: return "Question"
        case .task: return "Agent"
        }
    }

    private var isSubmitDisabled: Bool {
        if let options = request.question?.options, !options.isEmpty {
            return selectedOption == nil
        }
        return textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendResponse(_ decision: PermissionDecision) {
        let response = PermissionResponse(
            requestId: request.requestId,
            decision: decision,
            input: textInput.isEmpty ? nil : textInput,
            selectedOption: selectedOption
        )
        onResponse(response)
        dismiss()
    }
}

#Preview("Bash Command") {
    PermissionPromptView(
        request: PermissionRequest(
            type: "permission_request",
            requestId: "preview-1",
            promptType: .bash,
            toolName: "Bash",
            toolInput: ToolInput(command: "npm install", description: "Install dependencies"),
            context: nil,
            question: nil,
            permissionSuggestions: nil,
            timestamp: Date().timeIntervalSince1970
        ),
        onResponse: { _ in }
    )
}

#Preview("Edit File") {
    PermissionPromptView(
        request: PermissionRequest(
            type: "permission_request",
            requestId: "preview-2",
            promptType: .edit,
            toolName: "Edit",
            toolInput: nil,
            context: PermissionContext(
                filePath: "src/utils.ts",
                oldContent: "const foo = 1;",
                newContent: "const foo = 2;"
            ),
            question: nil,
            permissionSuggestions: nil,
            timestamp: Date().timeIntervalSince1970
        ),
        onResponse: { _ in }
    )
}

#Preview("Question - Options") {
    PermissionPromptView(
        request: PermissionRequest(
            type: "permission_request",
            requestId: "preview-3",
            promptType: .question,
            toolName: "AskUserQuestion",
            toolInput: nil,
            context: nil,
            question: PermissionQuestion(
                text: "Which database should we use?",
                options: ["PostgreSQL", "SQLite", "MongoDB"]
            ),
            permissionSuggestions: nil,
            timestamp: Date().timeIntervalSince1970
        ),
        onResponse: { _ in }
    )
}

#Preview("Question - Text Input") {
    PermissionPromptView(
        request: PermissionRequest(
            type: "permission_request",
            requestId: "preview-4",
            promptType: .question,
            toolName: "AskUserQuestion",
            toolInput: nil,
            context: nil,
            question: PermissionQuestion(
                text: "What should the function be named?",
                options: nil
            ),
            permissionSuggestions: nil,
            timestamp: Date().timeIntervalSince1970
        ),
        onResponse: { _ in }
    )
}
