import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.clipboard2backup` (declared in project.yml).
    static let clipboard2Backup = UTType(exportedAs: "at.softmaze.clippy.backup", conformingTo: .data)
}

/// Settings → General → Your data: Export and Import rows.
struct BackupRows: View {
    @State private var exporting = false
    @State private var importing: BackupFile?

    var body: some View {
        LabeledContent {
            Button("Export…") { exporting = true }
        } label: {
            Text("Back up")
            Text("History, pinned items and snippets — and secrets, if you choose — in one encrypted file.")
        }
        .sheet(isPresented: $exporting) { ExportBackupSheet() }

        LabeledContent {
            Button("Import…") { chooseBackup() }
        } label: {
            Text("Restore from a backup")
            Text("Adds what's missing. Nothing already here is changed or removed.")
        }
        .sheet(item: $importing) { ImportBackupSheet(file: $0) }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.clipboard2Backup]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose a Clipboard2 backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = BackupFile(url: url)
    }
}

struct BackupFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private enum BackupPassphrase {
    static let minimumLength = 8
}

// MARK: - Export

struct ExportBackupSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var includeSecrets = false
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var phase: Phase = .form
    @FocusState private var focused: Bool

    enum Phase: Equatable {
        case form
        case working
        case done(summary: String, file: URL)
        case failed(String)
    }

    private var problem: String? {
        if passphrase.count < BackupPassphrase.minimumLength { return "Use at least \(BackupPassphrase.minimumLength) characters." }
        if confirm != passphrase { return "The passphrases don't match." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch phase {
            case .done(let summary, let file):
                BackupResultView(symbol: "checkmark.circle.fill", tint: .green, title: "Backup Saved",
                                 message: "\(summary) saved to “\(file.lastPathComponent)”.") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            default:
                form
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(phase == .working)
    }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Export Backup").font(.title3.weight(.semibold))
            Text("Your history, pinned items and snippets on this Mac, encrypted with a passphrase you choose. Items in sync groups stay in their groups and aren't included.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 4) {
            Toggle("Include secrets", isOn: $includeSecrets)
            Text("You'll confirm with Touch ID first. Anyone with the file and its passphrase can read them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }

        VStack(alignment: .leading, spacing: 8) {
            SecureField("Passphrase", text: $passphrase, prompt: Text("Passphrase"))
                .focused($focused)
            SecureField("Repeat passphrase", text: $confirm, prompt: Text("Repeat passphrase"))
                .onSubmit { if problem == nil { export() } }
            Text("A forgotten passphrase can't be recovered, and without it the backup can't be opened.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .disabled(phase == .working)

        HStack(spacing: 8) {
            if case .failed(let message) = phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if phase == .working {
                ProgressView().controlSize(.small)
                Text("Encrypting…").font(.caption).foregroundStyle(.secondary)
            } else if let problem, !passphrase.isEmpty {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(phase == .working)
            Button("Export…") { export() }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || phase == .working)
        }
        .onAppear { focused = true }
    }

    private func export() {
        guard problem == nil, phase != .working else { return }
        Task {
            var secrets: [(ref: SecretRef, value: String)]?
            if includeSecrets {
                guard await env.secrets.authenticateNow(reason: "include your secrets in a backup") else { return }
                secrets = env.secrets.secrets
                    .filter { $0.spaceID == nil }
                    .compactMap { ref in SecretVault.value(id: ref.id).map { (ref: ref, value: $0) } }
            }
            guard let url = chooseDestination() else { return }
            let contents = BackupExporter.contents(store: env.store, snippets: env.snippets, secrets: secrets)
            phase = .working
            do {
                try await BackupExporter.write(contents, passphrase: passphrase, to: url)
                passphrase = ""
                confirm = ""
                phase = .done(summary: contents.summary.prefix(1).uppercased() + contents.summary.dropFirst(), file: url)
            } catch {
                phase = .failed("Couldn't save the backup: \(error.localizedDescription)")
            }
        }
    }

    private func chooseDestination() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.clipboard2Backup]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Clipboard2 Backup \(Date.now.formatted(.iso8601.year().month().day())).clipboard2backup"
        panel.prompt = "Export"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Import

struct ImportBackupSheet: View {
    let file: BackupFile
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var working = false
    @State private var error: String?
    @State private var summary: BackupImportSummary?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary {
                BackupResultView(symbol: summary.added > 0 ? "checkmark.circle.fill" : "equal.circle.fill",
                                 tint: summary.added > 0 ? .green : .secondary,
                                 title: summary.added > 0 ? "Backup Restored" : "Already Up to Date",
                                 message: summary.message) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(working)
    }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Restore “\(file.url.deletingPathExtension().lastPathComponent)”").font(.title3.weight(.semibold))
                .lineLimit(2)
            Text("Items, snippets and secrets that aren't here yet are added. Anything already here stays as it is.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        SecureField("Passphrase", text: $passphrase, prompt: Text("Backup passphrase"))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .focused($focused)
            .disabled(working)
            .onSubmit { restore() }
        HStack(spacing: 8) {
            if working {
                ProgressView().controlSize(.small)
                Text("Decrypting…").font(.caption).foregroundStyle(.secondary)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(working)
            Button("Restore") { restore() }
                .keyboardShortcut(.defaultAction)
                .disabled(passphrase.isEmpty || working)
        }
        .onAppear { focused = true }
    }

    private func restore() {
        guard !passphrase.isEmpty, !working else { return }
        working = true
        error = nil
        let url = file.url
        let passphrase = passphrase
        Task {
            defer { working = false }
            do {
                let document = try await BackupImporter.read(from: url, passphrase: passphrase)
                let sink: (any BackupSecretSink)? = (document.secrets?.isEmpty == false) ? env.secrets : nil
                summary = BackupImporter.merge(document, store: env.store, snippets: env.snippets,
                                               secrets: sink, maxAge: env.prefs.maxAge)
                self.passphrase = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The finished state of both sheets: a symbol, a title, one paragraph and the buttons.
private struct BackupResultView<Buttons: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        HStack {
            Spacer()
            buttons()
        }
    }
}
