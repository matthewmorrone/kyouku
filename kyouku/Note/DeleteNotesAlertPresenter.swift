import SwiftUI
import UIKit

struct DeleteNotesAlertPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let noteCount: Int
    let noteTitle: String?
    let hasAssociatedWords: Bool
    @Binding var deleteAssociatedWords: Bool
    let onCancel: () -> Void
    let onConfirmDelete: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard isPresented else {
            // If our alert is still presented, dismiss it.
            if let alert = context.coordinator.alert, alert.presentingViewController != nil {
                alert.dismiss(animated: true)
            }
            context.coordinator.alert = nil
            context.coordinator.toggleController = nil
            return
        }

        // Avoid presenting twice.
        if let alert = context.coordinator.alert {
            // Keep the embedded toggle in sync if SwiftUI state changes while the alert is up.
            context.coordinator.toggleController?.apply(
                isOn: deleteAssociatedWords,
                enabled: hasAssociatedWords,
                onChanged: { newValue in
                    deleteAssociatedWords = newValue
                }
            )
            // Ensure the message stays accurate if association state changes.
            let message: String = {
                if hasAssociatedWords {
                    return "This will delete the selected note(s). You can also delete any words saved from them."
                }
                return "This will delete the selected note(s)."
            }()
            if alert.message != message {
                alert.message = message
            }
            return
        }

        let title: String = {
            if noteCount == 1, let noteTitle, noteTitle.isEmpty == false {
                return "Delete \"\(noteTitle)\"?"
            }
            if noteCount > 1 {
                return "Delete \(noteCount) notes?"
            }
            return "Delete note?"
        }()
        let message: String = {
            if hasAssociatedWords {
                return "This will delete the selected note(s). You can also delete any words saved from them."
            }
            return "This will delete the selected note(s)."
        }()

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)

        if hasAssociatedWords {
            // Embed a checkbox-like control (UISwitch) inside the alert using a dedicated content VC.
            // This avoids brittle constraints against private UIAlertController subviews and prevents
            // spacing/hit-testing issues.
            let toggleController = AssociatedWordsToggleViewController()
            toggleController.apply(
                isOn: deleteAssociatedWords,
                enabled: true,
                onChanged: { newValue in
                    deleteAssociatedWords = newValue
                }
            )
            // Undocumented but common and stable: supplies a custom content view in `.alert` style.
            alert.setValue(toggleController, forKey: "contentViewController")
            context.coordinator.toggleController = toggleController
        } else {
            context.coordinator.toggleController = nil
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            onCancel()
            isPresented = false
        })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            onConfirmDelete()
            isPresented = false
        })

        context.coordinator.alert = alert
        uiViewController.present(alert, animated: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var alert: UIAlertController? = nil
        var toggleController: AssociatedWordsToggleViewController? = nil
    }
}

