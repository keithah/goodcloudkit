import SwiftUI
#if os(macOS)
import AppKit

/// Without a real .app bundle (we launch via `swift run`), an SPM SwiftUI executable
/// starts as a background accessory: no Dock icon and the window never comes forward.
/// Forcing a regular activation policy on launch fixes both.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif

@main
struct GoodCloudExampleApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 420, minHeight: 640)
        }
    }
}

/// Top-level router: shows a session check spinner, then either the login screen or the
/// authenticated device list, inside a single `NavigationStack`.
struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            content
        }
        .task { await model.checkExistingSession() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isCheckingSession {
            VStack(spacing: 12) {
                ProgressView()
                Text("Checking session…")
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.pageBackground)
        } else if model.isAuthenticated {
            DeviceListView(model: model)
        } else {
            LoginView(model: model)
        }
    }
}
