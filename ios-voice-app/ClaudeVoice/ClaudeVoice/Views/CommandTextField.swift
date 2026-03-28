// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CommandTextField.swift
import SwiftUI
import UIKit

class AutoGrowingTextView: UITextView {
    private static let maxHeight: CGFloat = 120

    override var intrinsicContentSize: CGSize {
        let size = sizeThatFits(CGSize(width: bounds.width, height: .infinity))
        let clamped = min(size.height, Self.maxHeight)
        isScrollEnabled = size.height > Self.maxHeight
        return CGSize(width: UIView.noIntrinsicMetric, height: clamped)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }
}

struct CommandTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var commandPrefix: String?
    var placeholder: String = "Message Claude..."
    var isDisabled: Bool = false
    var onTextChange: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> AutoGrowingTextView {
        let textView = AutoGrowingTextView()
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

        return textView
    }

    func updateUIView(_ textView: AutoGrowingTextView, context: Context) {
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

        textView.invalidateIntrinsicContentSize()
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

            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }
    }
}
