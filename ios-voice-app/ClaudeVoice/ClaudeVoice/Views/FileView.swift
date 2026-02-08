// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/FileView.swift
import SwiftUI

private let imageCache = NSCache<NSString, NSData>()

struct FileView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let filePath: String
    @Binding var selectedFilePathBinding: String?

    @State private var contents: String?
    @State private var imageData: Data?
    @State private var error: String?
    @State private var fileSize: Int?
    @State private var isLoading = true

    var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("Loading...")
                Spacer()
            } else if let error = error {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: errorIcon)
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(errorMessage)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else if let imageData = imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
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
        .enableSwipeBack()
        .onAppear {
            loadFile()
        }
    }

    private var errorIcon: String {
        switch error {
        case "file_too_large": return "exclamationmark.triangle"
        case "binary_file": return "doc.questionmark"
        default: return "doc.questionmark"
        }
    }

    private var errorMessage: String {
        switch error {
        case "file_too_large":
            let mb = (fileSize ?? 0) / (1024 * 1024)
            return "File too large to preview (\(mb) MB)"
        case "binary_file":
            return "Cannot view contents"
        default:
            return "Error: \(error ?? "Unknown")"
        }
    }

    private func loadFile() {
        // Check NSCache first
        let cacheKey = filePath as NSString
        if let cachedData = imageCache.object(forKey: cacheKey) {
            self.imageData = cachedData as Data
            self.isLoading = false
            return
        }

        requestFromServer()
    }

    private func requestFromServer() {
        webSocketManager.onFileContents = { response in
            guard response.path == filePath else { return }
            isLoading = false

            if let err = response.error {
                error = err
                fileSize = response.fileSize
            } else if let base64String = response.imageData,
                      let data = Data(base64Encoded: base64String) {
                imageData = data
                // Cache the image data
                imageCache.setObject(data as NSData, forKey: filePath as NSString)
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
                    Text("\(line.number)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                        .padding(.trailing, 8)

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
