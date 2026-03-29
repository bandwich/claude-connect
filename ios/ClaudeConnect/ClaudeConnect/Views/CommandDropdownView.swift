// ios-voice-app/ClaudeConnect/ClaudeConnect/Views/CommandDropdownView.swift
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
