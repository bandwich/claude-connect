// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionCardView.swift
import SwiftUI

struct PermissionCardView: View {
    let request: PermissionRequest
    let onResponse: (PermissionResponse) -> Void

    var body: some View {
        pendingView
    }

    private var pendingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Type label (colored)
            typeLabel

            // Content block (command, file, task description, or question)
            contentBlock

            // "Do you want to proceed?" + options
            optionsBlock
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .accessibilityIdentifier("permissionCard")
    }

    // MARK: - Type label

    private var typeLabel: some View {
        Text(typeLabelText)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(typeLabelColor)
    }

    private var typeLabelText: String {
        switch request.promptType {
        case .bash: return "Bash command"
        case .edit: return "Edit file"
        case .write: return "Create file"
        case .task: return "Agent"
        case .question: return "Question"
        }
    }

    private var typeLabelColor: Color {
        switch request.promptType {
        case .bash: return .orange
        case .edit: return .blue
        case .write: return .green
        case .task: return .purple
        case .question: return .primary
        }
    }

    // MARK: - Content block

    @ViewBuilder
    private var contentBlock: some View {
        switch request.promptType {
        case .bash:
            VStack(alignment: .leading, spacing: 4) {
                if let command = request.toolInput?.command {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(command)
                            .font(.system(.footnote, design: .monospaced))
                            .padding(8)
                    }
                    .background(Color(.systemGray5))
                    .cornerRadius(6)
                }
                if let desc = request.toolInput?.description {
                    Text(desc)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

        case .edit, .write:
            VStack(alignment: .leading, spacing: 4) {
                // File path from context or tool_input
                let path = request.context?.filePath ?? request.toolInput?.filePath
                if let path = path {
                    Text(path)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                // Diff from context or tool_input
                let oldContent = request.context?.oldContent ?? request.toolInput?.oldString
                let newContent = request.context?.newContent ?? request.toolInput?.newString
                if oldContent != nil || newContent != nil {
                    DiffView(
                        oldContent: oldContent ?? "",
                        newContent: newContent ?? "",
                        filePath: path ?? "file"
                    )
                    .frame(maxHeight: 200)
                }
            }

        case .task:
            if let desc = request.toolInput?.description {
                Text(desc)
                    .font(.caption)
                    .padding(8)
                    .background(Color(.systemGray5))
                    .cornerRadius(6)
            }

        case .question:
            if let text = request.question?.text {
                Text(text)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
        }
    }

    // MARK: - Options block

    @ViewBuilder
    private var optionsBlock: some View {
        if request.promptType == .question {
            questionOptions
        } else {
            permissionOptions
        }
    }

    private var permissionOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Do you want to proceed?")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Option 1: Yes
            optionButton(number: 1, text: "Yes") {
                sendResponse(.allow)
            }

            // Options from permission_suggestions (always-allow variants)
            if let suggestions = request.permissionSuggestions {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                    optionButton(number: index + 2, text: suggestion.displayText) {
                        sendResponse(.allow, updatedPermissions: [suggestion])
                    }
                }
            }

            // Last option: No
            let noNumber = 2 + (request.permissionSuggestions?.count ?? 0)
            optionButton(number: noNumber, text: "No") {
                sendResponse(.deny)
            }
        }
    }

    @State private var questionTextInput: String = ""

    @ViewBuilder
    private var questionOptions: some View {
        if let options = request.question?.options, !options.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    optionButton(number: index + 1, text: option) {
                        sendResponse(.allow, selectedOption: index)
                    }
                }
            }
        } else {
            HStack {
                TextField("Type your answer...", text: $questionTextInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("Send") {
                    sendResponse(.allow, input: questionTextInput)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(questionTextInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Option button

    private func optionButton(number: Int, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(number).")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(width: 22, alignment: .trailing)
                Text(text)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
            .background(Color(.systemGray5))
            .cornerRadius(8)
        }
        .accessibilityIdentifier("permissionOption\(number)")
    }

    // MARK: - Send response

    private func sendResponse(_ decision: PermissionDecision, updatedPermissions: [PermissionSuggestion]? = nil, input: String? = nil, selectedOption: Int? = nil) {
        let response = PermissionResponse(
            requestId: request.requestId,
            decision: decision,
            input: input,
            selectedOption: selectedOption,
            updatedPermissions: updatedPermissions
        )
        onResponse(response)
    }
}

#Preview("Bash - Pending") {
    PermissionCardView(
        request: PermissionRequest(
            type: "permission_request",
            requestId: "preview-1",
            promptType: .bash,
            toolName: "Bash",
            toolInput: ToolInput(command: "python3 -c \"print('hello from permission test')\"", description: "Test permission flow again"),
            context: nil,
            question: nil,
            permissionSuggestions: [
                PermissionSuggestion(
                    type: "addRules",
                    rules: [PermissionRule(toolName: "Bash", ruleContent: "python3:*")],
                    behavior: "allow",
                    destination: "localSettings"
                )
            ],
            timestamp: Date().timeIntervalSince1970
        ),
        onResponse: { _ in }
    )
    .padding()
}
