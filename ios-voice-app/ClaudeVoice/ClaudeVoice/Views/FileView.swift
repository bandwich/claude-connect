// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/FileView.swift
import SwiftUI

struct FileView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let filePath: String
    @Binding var selectedFilePathBinding: String?

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
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        FileContentView(contents: contents)
                            .frame(minHeight: geometry.size.height, alignment: .top)
                    }
                }
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .clipped()
        .customNavigationBar(
            title: fileName,
            breadcrumb: "Files",
            onBack: { selectedFilePathBinding = nil }
        ) {
            EmptyView()
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.trailing, 8)
    }
}

#Preview {
    NavigationStack {
        FileView(
            webSocketManager: WebSocketManager(),
            filePath: "/Users/aaron/Desktop/max/README.md",
            selectedFilePathBinding: .constant("/Users/aaron/Desktop/max/README.md")
        )
    }
}
