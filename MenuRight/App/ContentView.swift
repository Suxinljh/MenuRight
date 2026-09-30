import SwiftUI
import FinderSync

/// Phase A1 + A2.5 status page: extension status, management UI, and the
/// Folder Access settings section. Deliberately minimal.
struct ContentView: View {
    @State private var isExtensionEnabled = false
    @StateObject private var ipcStatus = IPCStatusCenter.shared

    var body: some View {
        VStack(spacing: 20) {
            Text("Menu Right")
                .font(.largeTitle.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                Text("Finder Extension")
                    .font(.headline)
                HStack(spacing: 8) {
                    Circle()
                        .fill(isExtensionEnabled ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(isExtensionEnabled ? "Enabled" : "Disabled")
                        .font(.body)
                }
                // Which copy is this window? The system enables the extension for
                // the copy it has registered, and that registration is per path.
                // Running the DerivedData build while ~/Applications is the
                // enabled one makes this window report "Disabled" even though
                // everything is fine — so show the path instead of letting the
                // user guess.
                Text(Bundle.main.bundlePath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if !isExtensionEnabled {
                    Text("This copy of the app is not the one the extension is enabled for. Install and run the registered copy (Scripts/install-dev-app.sh) — running from Xcode reports Disabled while Finder loads the installed build.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            Button("Manage Finder Extension") {
                FIFinderSyncController.showExtensionManagementInterface()
            }

            Divider()

            // The app is the extension's IPC server; if it is not listening,
            // every Finder action silently fails. That state used to be visible
            // only in the log, so show it here.
            VStack(alignment: .leading, spacing: 10) {
                Text("File Operations")
                    .font(.headline)
                HStack(spacing: 8) {
                    Circle()
                        .fill(ipcStatus.isHealthy ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(ipcStatus.displayText)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !ipcStatus.isHealthy {
                    Text("The Finder extension talks to this app over a socket in the shared App Group. While this is not Listening, Finder actions cannot complete.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            FolderAccessView()
        }
        .padding(28)
        .frame(width: 480)
        .onAppear {
            LifecycleDiagnostics.record("ContentView.onAppear", from: "main-app")
            refreshExtensionStatus()
        }
    }

    private func refreshExtensionStatus() {
        // macOS 10.14+. Deployment target is 14.0, so no availability gate needed.
        isExtensionEnabled = FIFinderSyncController.isExtensionEnabled
        // Logged explicitly: "why does the window say Disabled?" is otherwise
        // guesswork. Compare with `pluginkit -m -i xin.ljhsu.MenuRight.FinderSync -v`:
        // the system answers for the extension that is *registered and enabled*,
        // which is not necessarily the copy you are running.
        LifecycleDiagnostics.record(
            "extension status isExtensionEnabled=\(isExtensionEnabled)",
            from: "main-app"
        )
    }
}

#Preview {
    ContentView()
}
