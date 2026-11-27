import SwiftUI
import UIKit

/// "Share to Clipboard2" (docs/features/ios.md → Share extension): text, links, images and files
/// go into Copies, or into Saved with a label and folder. Saved in the shared store first, then
/// pushed right away when signed in; whatever doesn't make it is pushed by the app next time.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        let model = ShareModel(providers: providers) { [weak self] error in
            if let error {
                self?.extensionContext?.cancelRequest(withError: error)
            } else {
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}

@Observable
final class ShareModel {
    private let providers: [NSItemProvider]
    private let finish: ((any Error)?) -> Void
    private(set) var contents: [IncomingContent] = []
    private(set) var loading = true
    private(set) var working = false
    var save = false
    var label = ""
    var folderId: String?
    var error: String?
    let store = MobileStore()
    let session = SessionKeychain.load()

    /// How long the sheet waits for the upload before closing anyway (the app finishes it).
    static let pushTimeout: Duration = .seconds(15)

    init(providers: [NSItemProvider], finish: @escaping ((any Error)?) -> Void) {
        self.providers = providers
        self.finish = finish
        Task { await load() }
    }

    var spaceId: String { session?.personalSpaceId ?? "local" }

    var folders: [MobileFolder] {
        store.state.folders.filter { $0.spaceId == spaceId }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var summary: String {
        guard !contents.isEmpty else { return loading ? "" : "Nothing Clipboard2 can keep." }
        return contents.map { content in
            switch content {
            case .text(let text): TextPreview.make(text, limit: 140)
            case .url(let url): url.absoluteString
            case .image: "Image"
            case .files(let urls): urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
            }
        }.joined(separator: "\n")
    }

    private func load() async {
        contents = await IncomingContentLoader.loadAll(providers)
        loading = false
    }

    func cancel() { finish(CocoaError(.userCancelled)) }

    func add() async {
        working = true
        defer { working = false }
        let options = SaveOptions(save: save, label: label, folderId: save ? folderId : nil)
        do {
            for content in contents {
                let clip = try ClipImporter.makeClip(content, spaceId: spaceId, options: options)
                store.add(clip, options: options)
            }
        } catch {
            self.error = error.localizedDescription
            return
        }
        if let session, !session.expired {
            let sync = MobileSync(session: session, store: store, vault: nil)
            let push = Task { try? await sync.pushPersonal() }
            let timeout = Task {
                try? await Task.sleep(for: Self.pushTimeout)
                push.cancel()
            }
            _ = await push.value
            timeout.cancel()
        }
        finish(nil)
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.loading {
                        ProgressView()
                    } else {
                        Text(model.summary)
                            .lineLimit(6)
                            .foregroundStyle(model.contents.isEmpty ? .secondary : .primary)
                    }
                }
                Section {
                    Toggle("Save", isOn: $model.save)
                    if model.save {
                        TextField("Label (optional)", text: $model.label)
                        if !model.folders.isEmpty {
                            Picker("Folder", selection: $model.folderId) {
                                Text("None").tag(String?.none)
                                ForEach(model.folders) { folder in
                                    Text(folder.name).tag(String?.some(folder.id))
                                }
                            }
                        }
                    }
                } footer: {
                    Text(model.session == nil
                         ? "Kept on this iPhone. Sign in to Clipboard2 to sync it to your Mac."
                         : model.save ? "Added to Saved on all your devices." : "Added to Copies on all your devices.")
                }
                if let error = model.error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Share to Clipboard2")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.working {
                        ProgressView()
                    } else {
                        Button("Add") { Task { await model.add() } }
                            .disabled(model.loading || model.contents.isEmpty)
                    }
                }
            }
        }
    }
}
