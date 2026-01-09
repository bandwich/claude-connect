// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CustomNavigationBar.swift
import SwiftUI

/// Reusable navigation bar with trailing content inline with breadcrumb
struct CustomNavigationBarInline<TrailingContent: View>: ViewModifier {
    let title: String
    let breadcrumb: String
    let onBack: () -> Void
    @ViewBuilder let trailingContent: () -> TrailingContent

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 12) {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 0) {
                                Text(breadcrumb)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer(minLength: 8)
                                trailingContent()
                            }
                            Text(title)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
    }
}

/// Reusable navigation bar with trailing content as separate toolbar item
struct CustomNavigationBarTrailing<TrailingContent: View>: ViewModifier {
    let title: String
    let breadcrumb: String?
    let onBack: () -> Void
    @ViewBuilder let trailingContent: () -> TrailingContent

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 12) {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            if let breadcrumb = breadcrumb {
                                Text(breadcrumb)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(title)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    trailingContent()
                }
            }
    }
}

extension View {
    /// Navigation bar with trailing content inline with breadcrumb (e.g., branch indicator)
    func customNavigationBarInline<TrailingContent: View>(
        title: String,
        breadcrumb: String,
        onBack: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> TrailingContent
    ) -> some View {
        modifier(CustomNavigationBarInline(
            title: title,
            breadcrumb: breadcrumb,
            onBack: onBack,
            trailingContent: trailing
        ))
    }

    /// Navigation bar with trailing content as separate toolbar item (e.g., settings gear)
    func customNavigationBar<TrailingContent: View>(
        title: String,
        breadcrumb: String? = nil,
        onBack: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> TrailingContent
    ) -> some View {
        modifier(CustomNavigationBarTrailing(
            title: title,
            breadcrumb: breadcrumb,
            onBack: onBack,
            trailingContent: trailing
        ))
    }
}

