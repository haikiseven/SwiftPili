import SwiftUI
import UniformTypeIdentifiers

/// Only finalized app-owned artifacts reach this picker. Cancellation keeps the original artifact.
struct DownloadExportFilePicker: UIViewControllerRepresentable {
    let fileURL: URL
    let completion: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let completion: (URL?) -> Void
        private var settled = false

        init(completion: @escaping (URL?) -> Void) { self.completion = completion }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }

        private func finish(_ destination: URL?) {
            guard !settled else { return }
            settled = true
            completion(destination)
        }
    }
}
