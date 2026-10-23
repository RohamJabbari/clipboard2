import SwiftUI

/// One quiet line at the top of the menu bar menu while an update needs a click (or is on its way
/// after one). Nothing pops up on its own.
struct UpdateStatusRow: View {
    let updates: UpdateController

    /// The row, or nil when there's nothing worth a line.
    static func visible(for updates: UpdateController) -> UpdateStatusRow? {
        switch updates.phase {
        case .ready, .available, .installing: UpdateStatusRow(updates: updates)
        case .downloading, .preparing: updates.policy == .automatic ? nil : UpdateStatusRow(updates: updates)
        default: nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            switch updates.phase {
            case .ready(let version):
                Button { updates.installNow() } label: {
                    Label("Restart to Update to \(version)", systemImage: "arrow.clockwise.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                notesLink
            case .available(let version, let infoOnly):
                Button { updates.installNow() } label: {
                    Label(infoOnly ? "Clipboard2 \(version) is out — Learn More" : "Update to \(version)",
                          systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                if !infoOnly { notesLink }
            case .downloading(let fraction):
                ProgressView(value: fraction ?? 0).progressViewStyle(.linear).frame(width: 80)
                Text("Downloading update…").foregroundStyle(.secondary)
                Spacer()
            default:
                ProgressView().controlSize(.small)
                Text("Installing update…").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var notesLink: some View {
        Link("What's New", destination: updates.releaseNotesURL)
            .font(.caption)
    }
}

/// Settings → General → Updates: one choice, and the result of Check Now in place.
struct UpdatesSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let updates = env.updates
        Section {
            Picker("When there's a new version", selection: Binding(get: { updates.policy }, set: { updates.setPolicy($0) })) {
                ForEach(UpdatePolicy.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            LabeledContent {
                HStack(spacing: 10) {
                    status(updates)
                    actionButton(updates)
                }
            } label: {
                Text(versionLine)
                Text(updates.policy.summary)
            }
        } header: {
            Text("Updates")
        } footer: {
            HStack(spacing: 4) {
                Text("Verified and installed in place; your history stays.")
                Link("Release notes", destination: updates.releaseNotesURL)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        return "Clipboard2 \(short)"
    }

    @ViewBuilder
    private func status(_ updates: UpdateController) -> some View {
        switch updates.phase {
        case .checking:
            ProgressView().controlSize(.small)
            Text("Checking…").foregroundStyle(.secondary)
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let version, _):
            Text("\(version) available").foregroundStyle(.secondary)
        case .downloading(let fraction):
            if let fraction {
                ProgressView(value: fraction).frame(width: 90)
            } else {
                ProgressView().controlSize(.small)
            }
            Text("Downloading…").foregroundStyle(.secondary)
        case .preparing, .installing:
            ProgressView().controlSize(.small)
            Text("Preparing…").foregroundStyle(.secondary)
        case .ready(let version):
            Label("\(version) ready", systemImage: "arrow.down.circle.fill").foregroundStyle(.tint)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(message)
        case .idle:
            if let last = updates.lastCheck {
                Text("Checked \(last.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ updates: UpdateController) -> some View {
        switch updates.phase {
        case .ready:
            Button("Restart to Update") { updates.installNow() }
                .buttonStyle(.borderedProminent)
        case .available(_, let infoOnly):
            Button(infoOnly ? "Learn More" : "Update") { updates.installNow() }
        default:
            Button("Check Now") { updates.checkForUpdates() }
                .disabled(updates.isBusy)
        }
    }
}
