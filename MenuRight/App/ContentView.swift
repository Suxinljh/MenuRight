import SwiftUI
import FinderSync

/// Phase A1 status page: shows whether the Finder Sync Extension is enabled
/// and offers the system management UI. Deliberately minimal.
struct ContentView: View {
    @State private var isExtensionEnabled = false

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
        }
        .padding(28)
        .frame(width: 440)
        .onAppear {
            refreshExtensionStatus()
        }
    }

    private func refreshExtensionStatus() {
        // macOS 10.14+. Deployment target is 14.0, so no availability gate needed.
        isExtensionEnabled = FIFinderSyncController.isExtensionEnabled
    }
}

#Preview {
    ContentView()
}
