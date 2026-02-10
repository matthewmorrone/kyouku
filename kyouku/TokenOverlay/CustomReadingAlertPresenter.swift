import SwiftUI
import UIKit
import Foundation

struct CustomReadingAlertPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let title: String
    let surface: String
    @Binding var text: String
    let preferredLanguagePrefixes: [String]
    let onCancel: () -> Void
    let onApply: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard isPresented else {
            if let alert = context.coordinator.alert, alert.presentingViewController != nil {
                alert.dismiss(animated: true)
            }
            context.coordinator.alert = nil
            context.coordinator.entryController = nil
            return
        }

        if let alert = context.coordinator.alert {
            context.coordinator.entryController?.apply(
                surface: surface,
                text: text,
                preferredLanguagePrefixes: preferredLanguagePrefixes,
                onTextChanged: { newValue in
                    text = newValue
                }
            )
            _ = alert
            return
        }

        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        let entry = CustomReadingEntryViewController()
        entry.apply(
            surface: surface,
            text: text,
            preferredLanguagePrefixes: preferredLanguagePrefixes,
            onTextChanged: { newValue in
                text = newValue
            }
        )
        alert.setValue(entry, forKey: "contentViewController")

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            onCancel()
            isPresented = false
        })
        alert.addAction(UIAlertAction(title: "Apply", style: .default) { _ in
            onApply()
            isPresented = false
        })

        context.coordinator.alert = alert
        context.coordinator.entryController = entry
        uiViewController.present(alert, animated: true) {
            DispatchQueue.main.async {
                entry.focusAndSelectAll()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var alert: UIAlertController? = nil
        var entryController: CustomReadingEntryViewController? = nil
    }
}

