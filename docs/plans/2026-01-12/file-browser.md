# File Browser Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Add file browsing and viewing to the iOS app with a tabbed project view.

**Architecture:** Server provides directory listing and file content APIs via WebSocket. iOS app adds a tabbed ProjectDetailView with Sessions and Files tabs. FilesView shows expandable tree, FileView shows plain text.

**Tech Stack:** Python (server), Swift/SwiftUI (iOS)

**Risky Assumptions:**
- Large directories may be slow to list (verify with node_modules-sized folders)
- Binary file detection via UTF-8 decoding may be slow for large files (verify early)

---

## Task 1: Server - Add Directory and File Handlers

**Files:**
- Modify: `voice_server/ios_server.py`

**Step 1: Add list_directory handler**

Add to `VoiceServer` class after `handle_add_project`:

```python
async def handle_list_directory(self, websocket, data):
    """Handle list_directory request - returns files and folders in a directory"""
    path = data.get("path", "")

    if not path or not os.path.isdir(path):
        response = {
            "type": "directory_listing",
            "path": path,
            "entries": [],
            "error": "invalid_path"
        }
        await websocket.send(json.dumps(response))
        return

    try:
        entries = []
        for name in os.listdir(path):
            full_path = os.path.join(path, name)
            entry_type = "directory" if os.path.isdir(full_path) else "file"
            entries.append({"name": name, "type": entry_type})

        # Sort: directories first, then files, both alphabetical
        entries.sort(key=lambda e: (0 if e["type"] == "directory" else 1, e["name"].lower()))

        response = {
            "type": "directory_listing",
            "path": path,
            "entries": entries
        }
    except PermissionError:
        response = {
            "type": "directory_listing",
            "path": path,
            "entries": [],
            "error": "permission_denied"
        }

    await websocket.send(json.dumps(response))
```

**Step 2: Add read_file handler**

Add after `handle_list_directory`:

```python
async def handle_read_file(self, websocket, data):
    """Handle read_file request - returns file contents as text"""
    path = data.get("path", "")

    if not path or not os.path.isfile(path):
        response = {
            "type": "file_contents",
            "path": path,
            "error": "not_found"
        }
        await websocket.send(json.dumps(response))
        return

    try:
        with open(path, 'r', encoding='utf-8') as f:
            contents = f.read()

        response = {
            "type": "file_contents",
            "path": path,
            "contents": contents
        }
    except UnicodeDecodeError:
        response = {
            "type": "file_contents",
            "path": path,
            "error": "binary_file"
        }
    except PermissionError:
        response = {
            "type": "file_contents",
            "path": path,
            "error": "permission_denied"
        }

    await websocket.send(json.dumps(response))
```

**Step 3: Add message routing**

Add to `handle_message` method, in the if/elif chain:

```python
elif msg_type == 'list_directory':
    await self.handle_list_directory(websocket, data)
elif msg_type == 'read_file':
    await self.handle_read_file(websocket, data)
```

**Step 4: Verify server changes**

Run:
```bash
cd /Users/aaron/Desktop/max && python3 -c "
import sys
sys.path.insert(0, 'voice_server')
from ios_server import VoiceServer
v = VoiceServer()
print('handle_list_directory:', hasattr(v, 'handle_list_directory'))
print('handle_read_file:', hasattr(v, 'handle_read_file'))
"
```

Expected: Both print `True`

**Step 5: Commit**

```bash
git add voice_server/ios_server.py
git commit -m "feat: add list_directory and read_file WebSocket handlers"
```

---

## Task 2: iOS - Add Models and WebSocketManager Methods

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/FileModels.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`

**Step 1: Create file models**

Create `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/FileModels.swift`:

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Models/FileModels.swift
import Foundation

struct DirectoryEntry: Codable, Identifiable {
    let name: String
    let type: String  // "directory" or "file"

    var id: String { name }
    var isDirectory: Bool { type == "directory" }
}

struct DirectoryListingResponse: Codable {
    let type: String
    let path: String
    let entries: [DirectoryEntry]?
    let error: String?
}

struct FileContentsResponse: Codable {
    let type: String
    let path: String
    let contents: String?
    let error: String?
}
```

**Step 2: Add callbacks to WebSocketManager**

Add after `onPermissionResolved` declaration (~line 43):

```swift
var onDirectoryListing: ((DirectoryListingResponse) -> Void)?
var onFileContents: ((FileContentsResponse) -> Void)?
```

**Step 3: Add request methods to WebSocketManager**

Add after `addProject` method (~line 238):

```swift
func listDirectory(path: String) {
    let message: [String: Any] = [
        "type": "list_directory",
        "path": path
    ]
    sendJSON(message)
}

func readFile(path: String) {
    let message: [String: Any] = [
        "type": "read_file",
        "path": path
    ]
    sendJSON(message)
}
```

**Step 4: Add response handling in handleMessage**

Add in the string message parsing chain, after the `permissionResolved` handling (~line 376):

```swift
} else if let directoryListing = try? JSONDecoder().decode(DirectoryListingResponse.self, from: data) {
    logToFile("Decoded as DirectoryListingResponse: \(directoryListing.path)")
    DispatchQueue.main.async {
        self.onDirectoryListing?(directoryListing)
    }
} else if let fileContents = try? JSONDecoder().decode(FileContentsResponse.self, from: data) {
    logToFile("Decoded as FileContentsResponse: \(fileContents.path)")
    DispatchQueue.main.async {
        self.onFileContents?(fileContents)
    }
```

**Step 5: Build to verify**

Run:
```bash
cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

**Step 6: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/FileModels.swift
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift
git commit -m "feat: add directory listing and file reading to WebSocketManager"
```

---

## Task 3: iOS - Create ProjectDetailView with Tabs

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectDetailView.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectsListView.swift`

**Step 1: Create ProjectDetailView**

Create `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectDetailView.swift`:

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectDetailView.swift
import SwiftUI

enum ProjectTab: String, CaseIterable {
    case sessions = "Sessions"
    case files = "Files"
}

struct ProjectDetailView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let project: Project
    @Binding var showingBinding: Bool

    @State private var selectedTab: ProjectTab = .sessions
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(ProjectTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Tab content
            switch selectedTab {
            case .sessions:
                SessionsContentView(
                    webSocketManager: webSocketManager,
                    project: project
                )
            case .files:
                FilesView(
                    webSocketManager: webSocketManager,
                    project: project
                )
            }
        }
        .customNavigationBar(
            title: selectedTab.rawValue,
            breadcrumb: "/\(project.name)",
            onBack: { showingBinding = false }
        ) {
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.secondary)
            }
            .accessibilityIdentifier("settingsButton")
        }
        .enableSwipeBack()
        .sheet(isPresented: $showingSettings) {
            SettingsView(webSocketManager: webSocketManager)
        }
    }
}

// Extract SessionsListView content into a reusable view
struct SessionsContentView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let project: Project

    @State private var sessions: [Session] = []
    @State private var selectedSession: Session?
    @State private var isCreating = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List(sessions) { session in
                Button(action: {
                    selectedSession = session
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Text("\(session.messageCount) messages")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text(TimeFormatter.relativeTimeString(from: session.timestamp))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .padding(.top, 4)

            // Floating add button
            Button(action: createNewSession) {
                Image(systemName: "plus")
                    .font(.system(size: 20))
                    .foregroundColor(.primary)
                    .frame(width: 50, height: 50)
                    .background(Color(.systemBackground))
                    .cornerRadius(25)
                    .overlay(
                        Circle()
                            .stroke(Color(.separator), lineWidth: 1)
                    )
            }
            .padding(.trailing, 20)
            .padding(.bottom, 20)
            .accessibilityLabel("New Session")
        }
        .onAppear {
            webSocketManager.onSessionsReceived = { sessions in
                self.sessions = sessions
            }
            webSocketManager.requestSessions(folderName: project.folderName)
        }
        .navigationDestination(item: $selectedSession) { session in
            SessionView(
                webSocketManager: webSocketManager,
                project: project,
                session: session,
                selectedSessionBinding: $selectedSession
            )
        }
    }

    private func createNewSession() {
        guard !isCreating else { return }
        isCreating = true

        webSocketManager.onSessionActionResult = { response in
            isCreating = false
            if response.success {
                selectedSession = Session.newSession()
            }
        }

        webSocketManager.newSession(projectPath: project.path)
    }
}
```

**Step 2: Update ProjectsListView navigation**

In `ProjectsListView.swift`, change the `navigationDestination` (line 127-135) from:

```swift
.navigationDestination(isPresented: $showingSessionsList) {
    if let project = selectedProject {
        SessionsListView(
            webSocketManager: webSocketManager,
            project: project,
            showingBinding: $showingSessionsList
        )
    }
}
```

To:

```swift
.navigationDestination(isPresented: $showingSessionsList) {
    if let project = selectedProject {
        ProjectDetailView(
            webSocketManager: webSocketManager,
            project: project,
            showingBinding: $showingSessionsList
        )
    }
}
```

**Step 3: Build to verify**

Run:
```bash
cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```

Expected: Build will fail (FilesView doesn't exist yet) - that's expected at this step.

**Step 4: Commit (after Task 4 completes)**

This commit will happen after FilesView is created.

---

## Task 4: iOS - Create FilesView (Tree Browser)

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/FilesView.swift`

**Step 1: Create FilesView**

Create `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/FilesView.swift`:

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/FilesView.swift
import SwiftUI

struct FileTreeNode: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    var isExpanded: Bool = false
    var children: [FileTreeNode]? = nil
    var isLoading: Bool = false
}

struct FilesView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let project: Project

    @State private var rootNodes: [FileTreeNode] = []
    @State private var expandedPaths: Set<String> = []
    @State private var loadingPaths: Set<String> = []
    @State private var childrenCache: [String: [FileTreeNode]] = [:]
    @State private var selectedFilePath: String?

    var body: some View {
        List {
            ForEach(rootNodes) { node in
                FileTreeRow(
                    node: node,
                    depth: 0,
                    expandedPaths: $expandedPaths,
                    loadingPaths: $loadingPaths,
                    childrenCache: $childrenCache,
                    selectedFilePath: $selectedFilePath,
                    onToggle: { toggleNode($0) },
                    onSelect: { selectFile($0) }
                )
            }
        }
        .listStyle(.plain)
        .onAppear {
            loadRootDirectory()
        }
        .navigationDestination(item: $selectedFilePath) { path in
            FileView(
                webSocketManager: webSocketManager,
                filePath: path
            )
        }
    }

    private func loadRootDirectory() {
        webSocketManager.onDirectoryListing = { response in
            if response.path == project.path {
                if let entries = response.entries {
                    rootNodes = entries.map { entry in
                        FileTreeNode(
                            name: entry.name,
                            path: "\(project.path)/\(entry.name)",
                            isDirectory: entry.isDirectory
                        )
                    }
                }
            } else {
                // Child directory loaded
                if let entries = response.entries {
                    let children = entries.map { entry in
                        FileTreeNode(
                            name: entry.name,
                            path: "\(response.path)/\(entry.name)",
                            isDirectory: entry.isDirectory
                        )
                    }
                    childrenCache[response.path] = children
                    loadingPaths.remove(response.path)
                }
            }
        }
        webSocketManager.listDirectory(path: project.path)
    }

    private func toggleNode(_ path: String) {
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
            if childrenCache[path] == nil {
                loadingPaths.insert(path)
                webSocketManager.listDirectory(path: path)
            }
        }
    }

    private func selectFile(_ path: String) {
        selectedFilePath = path
    }
}

struct FileTreeRow: View {
    let node: FileTreeNode
    let depth: Int
    @Binding var expandedPaths: Set<String>
    @Binding var loadingPaths: Set<String>
    @Binding var childrenCache: [String: [FileTreeNode]]
    @Binding var selectedFilePath: String?
    let onToggle: (String) -> Void
    let onSelect: (String) -> Void

    var isExpanded: Bool { expandedPaths.contains(node.path) }
    var isLoading: Bool { loadingPaths.contains(node.path) }
    var children: [FileTreeNode]? { childrenCache[node.path] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                if node.isDirectory {
                    onToggle(node.path)
                } else {
                    onSelect(node.path)
                }
            }) {
                HStack(spacing: 6) {
                    // Indentation
                    if depth > 0 {
                        Spacer()
                            .frame(width: CGFloat(depth) * 20)
                    }

                    // Icon
                    if node.isDirectory {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                        }
                        Image(systemName: "folder.fill")
                            .foregroundColor(.blue)
                    } else {
                        Spacer()
                            .frame(width: 16)
                        Image(systemName: "doc.text")
                            .foregroundColor(.secondary)
                    }

                    Text(node.name)
                        .font(.subheadline)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded children
            if node.isDirectory && isExpanded, let children = children {
                ForEach(children) { child in
                    FileTreeRow(
                        node: child,
                        depth: depth + 1,
                        expandedPaths: $expandedPaths,
                        loadingPaths: $loadingPaths,
                        childrenCache: $childrenCache,
                        selectedFilePath: $selectedFilePath,
                        onToggle: onToggle,
                        onSelect: onSelect
                    )
                }
            }
        }
    }
}
```

**Step 2: Build to verify**

Run:
```bash
cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```

Expected: Build will fail (FileView doesn't exist yet) - that's expected.

**Step 3: Commit (after Task 5 completes)**

This commit will happen after FileView is created.

---

## Task 5: iOS - Create FileView (Text Viewer)

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/FileView.swift`

**Step 1: Create FileView**

Create `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/FileView.swift`:

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/FileView.swift
import SwiftUI

struct FileView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let filePath: String

    @State private var contents: String?
    @State private var error: String?
    @State private var isLoading = true

    var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File content
            if isLoading {
                Spacer()
                ProgressView("Loading...")
                Spacer()
            } else if let error = error {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(error == "binary_file" ? "Cannot view contents" : "Error: \(error)")
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if let contents = contents {
                ScrollView([.horizontal, .vertical]) {
                    FileContentView(contents: contents)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(fileName)
                    .font(.headline)
                    .lineLimit(1)
            }
        }
        .onAppear {
            loadFile()
        }
    }

    private func loadFile() {
        webSocketManager.onFileContents = { response in
            guard response.path == filePath else { return }
            isLoading = false

            if let err = response.error {
                error = err
            } else {
                contents = response.contents
            }
        }
        webSocketManager.readFile(path: filePath)
    }
}

struct FileContentView: View {
    let contents: String

    var lines: [(number: Int, text: String)] {
        contents.components(separatedBy: "\n").enumerated().map { ($0.offset + 1, $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines, id: \.number) { line in
                HStack(alignment: .top, spacing: 0) {
                    // Line number
                    Text("\(line.number)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                        .padding(.trailing, 8)

                    // Line content
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                }
                .padding(.vertical, 1)
            }
        }
        .padding(8)
    }
}

#Preview {
    NavigationStack {
        FileView(
            webSocketManager: WebSocketManager(),
            filePath: "/Users/aaron/Desktop/max/README.md"
        )
    }
}
```

**Step 2: Build to verify**

Run:
```bash
cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit all iOS changes**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/FileModels.swift
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectDetailView.swift
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/FilesView.swift
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/FileView.swift
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectsListView.swift
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift
git commit -m "feat: add file browser with tabbed project view"
```

---

## Task 6: Manual Verification

**Step 1: Start the server**

```bash
cd /Users/aaron/Desktop/max
source .venv/bin/activate
python3 voice_server/ios_server.py
```

**Step 2: Run app in simulator**

```bash
cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice
xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'
xcrun simctl boot "iPhone 16" 2>/dev/null || true
xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/ClaudeVoice-*/Build/Products/Debug-iphonesimulator/ClaudeVoice.app
xcrun simctl launch booted com.example.ClaudeVoice
```

**Step 3: Test the flow**

1. Connect to the server in Settings
2. Tap a project from the list
3. Verify you see "Sessions | Files" segmented control
4. Tap "Files" tab
5. Verify folder tree loads
6. Expand a folder by tapping it
7. Tap a text file (e.g., README.md)
8. Verify file contents display with line numbers
9. Tap a binary file (e.g., an image)
10. Verify "Cannot view contents" message

**CHECKPOINT:** If any step fails, debug before proceeding.

**Step 4: Final commit with docs**

```bash
git add docs/plans/2026-01-12/
git commit -m "docs: add file browser design and implementation plan"
```
