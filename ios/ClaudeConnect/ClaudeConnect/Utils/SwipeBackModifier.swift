// ios-voice-app/ClaudeConnect/ClaudeConnect/Utils/SwipeBackModifier.swift
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
        let controller = SwipeBackController()
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Also enable here in case navigation controller wasn't available in makeUIViewController
        uiViewController.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        uiViewController.navigationController?.interactivePopGestureRecognizer?.delegate = nil
    }
}

private class SwipeBackController: UIViewController {
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        // Enable swipe back when added to navigation hierarchy
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        navigationController?.interactivePopGestureRecognizer?.delegate = nil
    }
}

extension View {
    func enableSwipeBack() -> some View {
        modifier(EnableSwipeBack())
    }
}
