import SwiftUI
import MessageUI

// MARK: - MigrationAlertModifier
// Observes SorrivaDatabase.pendingMigrationEvent at app launch.
// Presents the appropriate alert once the UI is ready.
// Applied to ContentView via .migrationAlert().

struct MigrationAlertModifier: ViewModifier {

    @State private var showBackupFailedAlert    = false
    @State private var showMigrationFailedAlert = false
    @State private var migrationErrorText       = ""
    @State private var migrationRestored        = false
    @State private var showMailCompose          = false
    @State private var showShareSheet           = false
    @State private var shareItems: [Any]        = []

    func body(content: Content) -> some View {
        content
            .onAppear { checkForMigrationEvent() }

            // ── Backup failed alert ───────────────────────────────────────────
            .alert("Library Update Paused", isPresented: $showBackupFailedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("""
                    Sorriva could not back up your library before applying an update, \
                    so the update was cancelled. Your library is unchanged.

                    Error: \(migrationErrorText)
                    """)
            }

            // ── Migration failed alert ────────────────────────────────────────
            .alert(
                migrationRestored
                    ? "Library Update Failed — Data Restored"
                    : "Library Update Failed",
                isPresented: $showMigrationFailedAlert
            ) {
                Button("Send Diagnostic Report") { prepareDiagnosticReport() }
                Button("Dismiss", role: .cancel) {}
            } message: {
                Text(migrationRestored
                    ? """
                        An update to your library database failed. Your previous library \
                        has been fully restored and nothing was lost.

                        Would you like to send a diagnostic report to help us fix this?
                        """
                    : """
                        An update to your library database failed and the automatic restore \
                        also encountered an error. Your library may be in an inconsistent state.

                        Please send a diagnostic report so we can help resolve this.

                        Error: \(migrationErrorText)
                        """
                )
            }

            // ── Mail compose ──────────────────────────────────────────────────
            .sheet(isPresented: $showMailCompose) {
                MigrationDiagnosticMailView(
                    errorDescription: migrationErrorText,
                    onDismiss: { showMailCompose = false }
                )
            }

            // ── Share sheet fallback (no Mail account configured) ─────────────
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: shareItems)
            }
    }

    // MARK: - Private

    private func checkForMigrationEvent() {
        guard let event = SorrivaDatabase.pendingMigrationEvent else { return }
        switch event {
        case .backupFailed(let error):
            migrationErrorText = error
            showBackupFailedAlert = true
        case .migrationFailed(let error, let restored):
            migrationErrorText = error
            migrationRestored  = restored
            showMigrationFailedAlert = true
        }
    }

    private func prepareDiagnosticReport() {
        if MFMailComposeViewController.canSendMail() {
            showMailCompose = true
        } else {
            // No Mail account — fall back to system share sheet
            let logURL = SorrivaLogger.shared.logFileURL
            shareItems = [logURL]
            showShareSheet = true
        }
    }
}

// MARK: - MigrationDiagnosticMailView

struct MigrationDiagnosticMailView: UIViewControllerRepresentable {

    let errorDescription: String
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients(["support@sorriva.app"])
        vc.setSubject("Sorriva — Migration Failure Report")

        let appVersion  = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let iosVersion  = UIDevice.current.systemVersion
        let body = """
            Sorriva Migration Failure Report
            ─────────────────────────────────
            App version: \(appVersion) (\(buildNumber))
            iOS version: \(iosVersion)
            Device: \(UIDevice.current.model)

            Error:
            \(errorDescription)

            ─────────────────────────────────
            Diagnostic log attached.
            """
        vc.setMessageBody(body, isHTML: false)

        // Attach log file
        let logURL = SorrivaLogger.shared.logFileURL
        if let logData = try? Data(contentsOf: logURL) {
            vc.addAttachmentData(logData, mimeType: "text/plain", fileName: "sorriva-debug.log")
        }

        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController,
                                context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            controller.dismiss(animated: true)
            onDismiss()
        }
    }
}

// MARK: - View extension

extension View {
    /// Apply to the root view to surface migration alerts post-launch.
    func migrationAlert() -> some View {
        modifier(MigrationAlertModifier())
    }
}
