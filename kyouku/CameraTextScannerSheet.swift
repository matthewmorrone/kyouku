import SwiftUI
import VisionKit

struct CameraTextScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var detectedText: String = ""

    let onUseDetectedText: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    CameraTextScannerRepresentable(detectedText: $detectedText)
                } else {
                    ContentUnavailableView(
                        "Camera Unavailable",
                        systemImage: "camera.fill",
                        description: Text("Live Text scanning is unavailable on this device right now.")
                    )
                }
            }
            .navigationTitle("Scan Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use Text") {
                        onUseDetectedText(detectedText)
                        dismiss()
                    }
                    .disabled(detectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct CameraTextScannerRepresentable: UIViewControllerRepresentable {
    @Binding var detectedText: String

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(detectedText: $detectedText)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        @Binding var detectedText: String

        init(detectedText: Binding<String>) {
            _detectedText = detectedText
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            applyRecognizedItems(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didUpdate updatedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            applyRecognizedItems(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didRemove removedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            applyRecognizedItems(allItems)
        }

        private func applyRecognizedItems(_ items: [RecognizedItem]) {
            let lines: [String] = items.compactMap { item in
                guard case .text(let text) = item else { return nil }
                return text.transcript
            }

            detectedText = lines.joined(separator: "\n")
        }
    }
}
