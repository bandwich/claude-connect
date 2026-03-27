// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CommandTextField.swift
import SwiftUI
import UIKit

struct CommandTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var dynamicHeight: CGFloat
    var commandPrefix: String?
    var placeholder: String = "Message Claude..."
    var isDisabled: Bool = false
    var onTextChange: ((String) -> Void)?

    private static let maxHeight: CGFloat = 120
    private static let defaultHeight: CGFloat = 36

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 17)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.isScrollEnabled = false
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.accessibilityIdentifier = "messageTextField"

        // Placeholder label
        let placeholderLabel = UILabel()
        placeholderLabel.text = placeholder
        placeholderLabel.font = .systemFont(ofSize: 17)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.tag = 999
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 13),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
        ])

        // Report initial height
        DispatchQueue.main.async {
            self.recalculateHeight(textView)
        }

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // Update disabled state
        textView.isEditable = !isDisabled
        textView.isUserInteractionEnabled = !isDisabled
        textView.alpha = isDisabled ? 0.5 : 1.0

        // Update text + attributed styling only if text changed externally
        let currentPlain = textView.text ?? ""
        if currentPlain != text {
            applyAttributedText(to: textView)
        } else if context.coordinator.lastCommandPrefix != commandPrefix {
            // Command prefix changed (selection happened) — restyle
            applyAttributedText(to: textView)
        }
        context.coordinator.lastCommandPrefix = commandPrefix

        // Placeholder visibility
        if let placeholderLabel = textView.viewWithTag(999) as? UILabel {
            placeholderLabel.isHidden = !text.isEmpty
        }

        // Focus management
        if isFocused && !textView.isFirstResponder {
            DispatchQueue.main.async { textView.becomeFirstResponder() }
        } else if !isFocused && textView.isFirstResponder {
            DispatchQueue.main.async { textView.resignFirstResponder() }
        }

        // Recalculate height when text changes externally (e.g., cleared after send)
        recalculateHeight(textView)
    }

    private func recalculateHeight(_ textView: UITextView) {
        let size = textView.sizeThatFits(CGSize(width: textView.frame.width, height: .infinity))
        let newHeight = min(max(size.height, Self.defaultHeight), Self.maxHeight)
        textView.isScrollEnabled = size.height > Self.maxHeight
        if dynamicHeight != newHeight {
            dynamicHeight = newHeight
        }
    }

    private func applyAttributedText(to textView: UITextView) {
        let fullText = text
        let attributed = NSMutableAttributedString(
            string: fullText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 17),
                .foregroundColor: UIColor.label,
            ]
        )

        // Color the command prefix blue
        if let prefix = commandPrefix, !prefix.isEmpty,
           fullText.hasPrefix(prefix) {
            let range = NSRange(location: 0, length: prefix.count)
            attributed.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: range)
        }

        // Preserve cursor position
        let selectedRange = textView.selectedRange
        textView.attributedText = attributed
        if selectedRange.location + selectedRange.length <= fullText.count {
            textView.selectedRange = selectedRange
        }

        // Reset typing attributes so new text after the prefix isn't blue
        textView.typingAttributes = [
            .font: UIFont.systemFont(ofSize: 17),
            .foregroundColor: UIColor.label,
        ]
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: CommandTextField
        var lastCommandPrefix: String?

        init(_ parent: CommandTextField) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            let newText = textView.text ?? ""
            parent.text = newText
            parent.onTextChange?(newText)

            // Update placeholder
            if let placeholderLabel = textView.viewWithTag(999) as? UILabel {
                placeholderLabel.isHidden = !newText.isEmpty
            }

            // Recalculate height for SwiftUI layout
            parent.recalculateHeight(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }
    }
}
