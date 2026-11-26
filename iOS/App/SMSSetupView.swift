import SwiftUI

/// Settings → Set up SMS codes (docs/features/ios.md → SMS codes).
///
/// iOS has no API to create a personal automation, and no URL opens the Automation tab or a new
/// automation (Shortcuts' documented URLs open the app, a shortcut, or the editor for a new
/// shortcut). "Save Sign-in Code" is an App Shortcut, so the action is already in Shortcuts with
/// nothing to install. The shortest path is one button that opens Shortcuts, plus these steps.
struct SMSSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var sample = ""
    @State private var sampleSender = ""

    static let shortcutsURL = URL(string: "shortcuts://")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        openURL(Self.shortcutsURL)
                    } label: {
                        Label("Open Shortcuts", systemImage: "square.2.layers.3d")
                            .font(.headline)
                    }
                } footer: {
                    Text("iOS doesn't let apps create automations, so this takes six taps in Shortcuts, once. The steps are below; come back here to test it.")
                }

                Section("In Shortcuts") {
                    step(1, "Tap **Automation** at the bottom, then **+** (or **New Automation**).")
                    step(2, "Choose **Message**. Leave Sender on **Any Sender**. If “Message Contains” must be filled in, type **code**.")
                    step(3, "Choose **Run Immediately** and turn off **Notify When Run**. Tap **Next**.")
                    step(4, "Tap **New Blank Automation**, then **Add Action**, and search for **Save Sign-in Code** (Clipboard2).")
                    step(5, "Tap **Message** in the action and pick **Shortcut Input**. Tap **Sender**, pick **Shortcut Input** again, then tap that blue token and choose **Sender**.")
                    step(6, "Tap **Done**. From now on, every text runs it; most have no code and nothing happens.")
                }

                Section {
                    TextField("Paste a text message", text: $sample, axis: .vertical)
                        .lineLimit(2...6)
                    TextField("Sender (optional)", text: $sampleSender)
                        .textInputAutocapitalization(.never)
                    if !sample.isEmpty {
                        let result = SMSCodeExtractor.extract(sample)
                        let match = SMSOriginMatcher.match(message: sample, sender: sampleSender.isEmpty ? nil : sampleSender,
                                                           boundDomain: result?.boundDomain)
                        LabeledContent("Code", value: result?.code ?? "None found")
                        LabeledContent("Site", value: match?.domain ?? "Unknown")
                    }
                } header: {
                    Text("Test")
                } footer: {
                    Text("Shows what would be saved; nothing is stored. iPhone also suggests codes from Messages above the keyboard; this puts them in Auth, under their site.")
                }
            }
            .navigationTitle("SMS Codes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint.opacity(0.2)))
            Text(text)
        }
    }
}
