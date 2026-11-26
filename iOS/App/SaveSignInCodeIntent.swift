import AppIntents
import Foundation

/// "Save Sign-in Code" (docs/features/ios.md → SMS codes): what a Shortcuts automation runs for
/// every text message, with the message and its sender. Runs in the background; nothing opens.
struct SaveSignInCodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Sign-in Code"
    static let description = IntentDescription(
        "Finds a sign-in code in a text message and keeps it in Clipboard2's Auth for 10 minutes, under the site it's for. The message itself isn't kept.",
        categoryName: "Codes")
    static let openAppWhenRun = false

    @Parameter(title: "Message", description: "The message text (in an automation: Shortcut Input → Content).",
               inputOptions: String.IntentInputOptions(multiline: true))
    var message: String

    @Parameter(title: "Sender", description: "Who sent it (in an automation: Shortcut Input → Sender).")
    var sender: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Save sign-in code from \(\.$message)") {
            \.$sender
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let code = SignInCodeStore.shared.save(message: message, sender: sender) else {
            // Most messages have no code: stay quiet.
            return .result(value: "")
        }
        return .result(value: code.code)
    }
}

struct Clipboard2Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SaveSignInCodeIntent(),
                    phrases: ["Save sign-in code in \(.applicationName)",
                              "Save a code with \(.applicationName)"],
                    shortTitle: "Save Sign-in Code",
                    systemImageName: "key.viewfinder")
    }
}
