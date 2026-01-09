// ios-voice-app/ClaudeVoice/ClaudeVoice/Utils/SwipeBackModifier.swift
import SwiftUI
import UIKit

struct EnableSwipeBack: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(SwipeBackEnabler())
    }
}

private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        return UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Configure gesture recognizer here - runs after view controller is in hierarchy
        uiViewController.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        uiViewController.navigationController?.interactivePopGestureRecognizer?.delegate = nil
    }
}

extension View {
    func enableSwipeBack() -> some View {
        modifier(EnableSwipeBack())
    }
}
