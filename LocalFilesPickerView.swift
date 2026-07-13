import SwiftUI
import UniformTypeIdentifiers

// MARK: - LocalFilesPickerView
// Phase 1b — iOS Files source
// Presents UIDocumentPickerViewController in folder mode.
// Saves a security-scoped bookmark as a LibrarySource (type: "files").

struct LocalFilesPickerView: View {
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var error: String? = nil

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.sGradientTop, Color.sGradientMid, Color.sGradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {

                Spacer()

                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(hex: "#4CAF50").opacity(0.15))
                        .frame(width: 80, height: 80)
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 36))
                        .foregroundColor(Color(hex: "#4CAF50"))
                }

                VStack(spacing: 8) {
                    Text("Add Local Files")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.sTextPrimary)
                    Text("Choose a folder from your iPhone, a connected USB-C drive, or iCloud Drive. Sorriva will remember it for scanning.")
                        .font(.system(size: 14))
                        .foregroundColor(.sTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                if let err = error {
                    HStack(alignment: .top, spacing: 4) {
                        Text("*")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.red)
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 32)
                }

                Button {
                    showPicker = true
                } label: {
                    Text("Choose Folder")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.sAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 32)

                Spacer()
            }
        }
        .navigationTitle("Local Files")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            FolderPickerRepresentable { url in
                saveSource(url: url)
            } onError: { message in
                error = message
            }
        }
    }

    private func saveSource(url: URL) {
        // Start accessing the security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            error = "Could not access the selected folder."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        // Create a security-scoped bookmark so we can re-access after app restart
        do {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let folderName = url.lastPathComponent
            let now = Int(Date().timeIntervalSince1970)
            let source = LibrarySource(
                id: UUID().uuidString,
                type: "files",
                displayName: folderName,
                host: "local",
                share: "files",
                rootPath: bookmark.base64EncodedString(),
                username: nil,
                password: nil,
                lastScanned: nil,
                trackCount: 0,
                scanState: "idle",
                createdAt: now,
                updatedAt: now
            )
            try? SorrivaDatabase.shared.upsertLibrarySource(source)
            print("SORRIVA Files: Saved '\(folderName)' bookmark")
            onSaved()
            dismiss()
        } catch {
            self.error = "Could not save folder access: \(error.localizedDescription)"
        }
    }
}

// MARK: - FolderPickerRepresentable
// UIViewControllerRepresentable wrapper for UIDocumentPickerViewController in folder mode.

struct FolderPickerRepresentable: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onError: onError)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        let onError: (String) -> Void

        init(onPicked: @escaping (URL) -> Void, onError: @escaping (String) -> Void) {
            self.onPicked = onPicked
            self.onError = onError
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onError("No folder was selected.")
                return
            }
            onPicked(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // User cancelled — no error, just dismiss
        }
    }
}
