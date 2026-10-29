import SwiftUI
import SwiftData

@main
enum Clipboard2Main {
    static func main() {
        // A short-lived copy started only to ask macOS for the current Screen Recording state.
        if CommandLine.arguments.contains(ScreenRecordingPermission.probeArgument) {
            exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
        }
        Clipboard2App.main()
    }
}

struct Clipboard2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(AppEnvironment.shared)
                .modelContainer(AppEnvironment.shared.container)
        } label: {
            MenuBarLabel()
                .environment(AppEnvironment.shared)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(AppEnvironment.shared)
                .modelContainer(AppEnvironment.shared.container)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppEnvironment.isRunningTests else { return }
        AppEnvironment.shared.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            AppEnvironment.shared.handle(url: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
