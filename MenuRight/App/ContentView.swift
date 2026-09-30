import SwiftUI

/// App root.
///
/// The window is the settings UI: a native sidebar on the left, the selected
/// pane on the right. The status information that used to fill this window (the
/// Finder extension state and the IPC channel) now lives in the General pane,
/// so nothing was lost when the window became a settings surface.
struct ContentView: View {
    var body: some View {
        SettingsRootView()
            .onAppear {
                LifecycleDiagnostics.record("ContentView.onAppear", from: "main-app")
            }
    }
}

#Preview {
    ContentView()
}
