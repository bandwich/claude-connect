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
                filePath: path,
                selectedFilePathBinding: $selectedFilePath
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
