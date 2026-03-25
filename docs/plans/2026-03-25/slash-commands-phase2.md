# Slash Commands Phase 2: iOS UI (Dropdown + Attributed Text Field)

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** When the user types `/` as the first character, a dropdown overlay appears above the text field with filtered commands. Selecting a command inserts it into the text field styled in blue. The text field uses attributed text (UITextView wrapper) to color the `/command` prefix.

**Architecture:** `CommandTextField` wraps UITextView via UIViewRepresentable for attributed text. `CommandDropdownView` is a SwiftUI overlay anchored above the text field. SessionView replaces its TextField with CommandTextField and adds the dropdown overlay. Filtering and blue styling are driven by `@State` in SessionView.

**Tech Stack:** Swift, SwiftUI, UIKit (UITextView via UIViewRepresentable)

**Risky Assumptions:** UITextView can be wrapped in UIViewRepresentable with two-way text binding, focus state, and attributed string updates without fighting SwiftUI's layout system. This is the Phase 1 deliverable — verify it works before building the dropdown on top. Multi-line (1-5 lines) auto-sizing should work via UITextView's intrinsic content size with a max height constraint.

**Prerequisite:** Phase 1 must be complete (server sends commands, iOS stores them in `WebSocketManager.availableCommands`).

---

### Task 1: CommandTextField (UIViewRepresentable)

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CommandTextField.swift`

**Step 1: Write the implementation**

This is the risky component — a UITextView wrapped for SwiftUI. We build it first and verify manually since UIViewRepresentable components are not unit-testable in isolation (they need a hosted SwiftUI view).

Create `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CommandTextField.swift`:

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CommandTextField.swift
import SwiftUI
import UIKit

struct CommandTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool  // Bridge from @State, NOT @FocusState (incompatible with @Binding)
    var commandPrefix: String?  // e.g. "/compact" — this portion renders blue
    var placeholder: String = "Message Claude..."
    var isDisabled: Bool = false
    var onTextChange: ((String) -> Void)?

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

        // Max height constraint (5 lines)
        let maxHeight: CGFloat = 120  // ~5 lines at size 17
        textView.isScrollEnabled = textView.contentSize.height > maxHeight
        if textView.isScrollEnabled {
            // Apply max height via frame if in scroll mode
            let currentFrame = textView.frame
            if currentFrame.height != maxHeight {
                textView.frame = CGRect(origin: currentFrame.origin, size: CGSize(width: currentFrame.width, height: maxHeight))
                textView.invalidateIntrinsicContentSize()
            }
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
        // Restore cursor if valid
        if selectedRange.location + selectedRange.length <= fullText.count {
            textView.selectedRange = selectedRange
        }
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

            // Invalidate intrinsic content size for auto-height
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
```

**Step 2: Replace TextField in SessionView**

Modify `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`:

1. Replace `@FocusState private var isTextFieldFocused: Bool` (line 36) with a regular `@State`:
```swift
    @State private var isTextFieldFocused: Bool = false
```
`@FocusState` is incompatible with `@Binding` — CommandTextField needs a `@Binding<Bool>` to manage focus. Also remove the `.focused($isTextFieldFocused)` modifier that was on the old TextField (it's now handled internally by CommandTextField).

2. Add state variables for command prefix (near other `@State` declarations around line 24):
```swift
    @State private var selectedCommandPrefix: String? = nil
    @State private var showCommandDropdown: Bool = false
```

2. Replace the TextField block (lines ~397-407) with:
```swift
                // Text field
                CommandTextField(
                    text: $messageText,
                    isFocused: $isTextFieldFocused,
                    commandPrefix: selectedCommandPrefix,
                    isDisabled: speechRecognizer.isRecording
                ) { newText in
                    // Track slash prefix for dropdown
                    if newText.hasPrefix("/") && !newText.contains(" ") {
                        showCommandDropdown = true
                    } else if !newText.hasPrefix("/") {
                        showCommandDropdown = false
                        selectedCommandPrefix = nil
                    } else if selectedCommandPrefix != nil {
                        // User typed space after a command — keep prefix, hide dropdown
                        showCommandDropdown = false
                    }
                }
                .frame(minHeight: 36)
                .background(Color(.systemGray6))
                .cornerRadius(20)
                .accessibilityIdentifier("messageTextField")
```

**Step 3: Build and verify on simulator**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

**Step 4: Manual verification**

Launch in simulator. Verify:
- Text field appears and is tappable
- Typing works, text appears
- Multi-line works (type long text)
- Placeholder "Message Claude..." shows when empty
- Send button still works
- Mic button still works
- Image picker still works

**CHECKPOINT:** If the text field doesn't work properly (crashes, layout broken, focus issues), debug before proceeding. This is the risky part.

**Step 5: Commit**

```bash
cd /Users/aaron/Desktop/max && git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CommandTextField.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift && git commit -m "feat: add CommandTextField with attributed text support"
```

---

### Task 2: CommandDropdownView

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CommandDropdownView.swift`

**Step 1: Write the implementation**

Create `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CommandDropdownView.swift`:

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CommandDropdownView.swift
import SwiftUI

struct CommandDropdownView: View {
    let commands: [SlashCommand]
    let filter: String  // text after "/" e.g. "com"
    let onSelect: (SlashCommand) -> Void

    private var filteredCommands: [SlashCommand] {
        if filter.isEmpty {
            return commands
        }
        let lowerFilter = filter.lowercased()
        return commands.filter { $0.name.lowercased().hasPrefix(lowerFilter) }
    }

    var body: some View {
        let filtered = filteredCommands
        if filtered.isEmpty {
            EmptyView()
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                            Button {
                                onSelect(command)
                            } label: {
                                HStack(spacing: 8) {
                                    Text("/\(command.name)")
                                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                        .foregroundColor(index == 0 ? .white : .primary)
                                    Text(command.description)
                                        .font(.system(size: 13))
                                        .foregroundColor(index == 0 ? .white.opacity(0.8) : .secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(index == 0 ? Color.blue : Color.clear)
                                .cornerRadius(6)
                            }
                            .id(command.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(maxHeight: 300)
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: -2)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(.systemGray4), lineWidth: 0.5)
            )
        }
    }
}
```

**Step 2: Build to verify compilation**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
cd /Users/aaron/Desktop/max && git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CommandDropdownView.swift && git commit -m "feat: add CommandDropdownView for slash command autocomplete"
```

---

### Task 3: Wire dropdown into SessionView

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

**Step 1: Add the dropdown overlay**

In SessionView, the dropdown should appear above the input bar when `showCommandDropdown` is true. Modify the input bar area (around line 176 where the `VStack(spacing: 0)` input bar section begins).

Add the dropdown just above the `HStack(alignment: .bottom, spacing: 8)` input row (around line 383), inside the `.normal` case:

```swift
                    case .normal:
                        // Slash command dropdown
                        if showCommandDropdown {
                            let slashFilter = String(messageText.dropFirst())  // remove "/"
                            CommandDropdownView(
                                commands: webSocketManager.availableCommands,
                                filter: slashFilter
                            ) { command in
                                messageText = "/\(command.name) "
                                selectedCommandPrefix = "/\(command.name)"
                                showCommandDropdown = false
                            }
                            .padding(.horizontal, 12)
                            .transition(.opacity)
                        }
                        normalInputBar
```

**Step 2: Replace the `onTextChange` callback in CommandTextField**

Replace the `onTextChange` closure from Task 1 Step 2 with this improved version that handles edge cases (backspace, editing the prefix):

```swift
                ) { newText in
                    if newText.hasPrefix("/") && selectedCommandPrefix == nil {
                        // Typing a slash command — show dropdown
                        showCommandDropdown = true
                    } else if !newText.hasPrefix("/") {
                        // No longer starts with / — clear everything
                        showCommandDropdown = false
                        selectedCommandPrefix = nil
                    } else if selectedCommandPrefix != nil && !newText.hasPrefix(selectedCommandPrefix!) {
                        // User edited the command prefix — reset
                        selectedCommandPrefix = nil
                        showCommandDropdown = true
                    }
                }
```

**Step 3: Handle dropdown dismissal on send**

In `sendTextMessage()` (around line 1020), add cleanup:
```swift
        selectedCommandPrefix = nil
        showCommandDropdown = false
```
Add these after `messageText = ""` (around line 1033).

**Step 4: Build and manual verification**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

**Step 5: Manual verification (requires server running)**

1. Start server: `claude-connect`
2. Connect iOS app
3. Open a session
4. Type `/` — dropdown should appear with full command list
5. Type `/com` — list filters to compact, commit, etc.
6. Top item should be highlighted in blue
7. Tap "compact" — text field shows `/compact ` with blue prefix
8. Type arguments: `focus on tests`
9. Tap send — message sends normally
10. Type `/` then delete it — dropdown dismisses

**CHECKPOINT:** All 10 verification steps must pass. Debug any failures before committing.

**Step 6: Commit**

```bash
cd /Users/aaron/Desktop/max && git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift && git commit -m "feat: wire slash command dropdown into session input bar"
```

---

### Task 4: Build and deploy to device

**Step 1: Build for device**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild -target ClaudeVoice -sdk iphoneos build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

**Step 2: Install on device**

```bash
xcrun devicectl list devices
# Use device ID from output:
xcrun devicectl device install app --device "<DEVICE_ID>" ios-voice-app/ClaudeVoice/build/Release-iphoneos/ClaudeVoice.app
```

**Step 3: Manual verification on device**

Same verification steps as Task 3 Step 5, but on the physical device. Pay extra attention to:
- Keyboard interaction (does dropdown appear above keyboard correctly?)
- Scroll behavior (does dropdown scroll with many items?)
- Performance (does filtering feel instant?)
- Blue text styling visible and correct?

**CHECKPOINT:** Feature works end-to-end on device before merging.

**Step 4: Commit (if any device-specific fixes needed)**

```bash
cd /Users/aaron/Desktop/max && git add -A && git commit -m "fix: device-specific adjustments for slash commands UI"
```
