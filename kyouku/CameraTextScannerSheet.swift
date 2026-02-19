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
        CustomLogger.shared.pipeline(context: "OCR", stage: "Start", "Creating DataScannerViewController")
        let controller = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        do {
            try controller.startScanning()
            CustomLogger.shared.pipeline(context: "OCR", stage: "Start", "startScanning succeeded")
        } catch {
            let nsError = error as NSError
            CustomLogger.shared.pipeline(
                context: "OCR",
                stage: "Error",
                "startScanning failed domain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription)",
                level: .error
            )
            CustomLogger.shared.raw("[OCR][Error] startScanning failed: \(nsError)")
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
        CustomLogger.shared.pipeline(context: "OCR", stage: "Stop", "stopScanning called")
    }

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

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            CustomLogger.shared.pipeline(
                context: "OCR",
                stage: "Error",
                "Scanner became unavailable: \(error)",
                level: .error
            )
            CustomLogger.shared.raw("[OCR][Error] Scanner became unavailable: \(error)")
        }

        private func applyRecognizedItems(_ items: [RecognizedItem]) {
            let lines: [String] = items.compactMap { item in
                guard case .text(let text) = item else { return nil }
                return text.transcript
            }

            detectedText = lines.joined(separator: "\n")

            if detectedText.isEmpty {
                CustomLogger.shared.pipeline(context: "OCR", stage: "Update", "No text recognized in current frame")
            }
        }
    }
}
