import Foundation
import LocalAuthentication
import Observation
import UIKit
import UniformTypeIdentifiers

/// The app's state: the session, the stores and sync.
@Observable
final class AppModel {
    let store: MobileStore
    let vault: MobileVault
    let codes: SignInCodeStore
    let passwordless: any PasswordlessSignIn
    private(set) var session: MobileSession?
    private(set) var isSyncing = false
    var errorMessage: String?
    /// A short confirmation ("Copied"), cleared after a moment.
    var notice: String?
    private var sync: MobileSync?
    private var pollTask: Task<Void, Never>?

    static let pollInterval: Duration = .seconds(20)

    init(store: MobileStore = MobileStore(), vault: MobileVault = MobileVault(), codes: SignInCodeStore = .shared,
         passwordless: any PasswordlessSignIn = PasswordlessSignInStub()) {
        self.store = store
        self.vault = vault
        self.codes = codes
        self.passwordless = passwordless
        if let session = SessionKeychain.load() { adopt(session) }
    }

    var isSignedIn: Bool { session != nil }
    var needsPassword: Bool { session?.expired == true }
    /// Where new clips go: the personal space, or (signed out) a local-only placeholder that's
    /// moved into the personal space at sign-in.
    var personalSpaceId: String { session?.personalSpaceId ?? Self.localSpace }
    static let localSpace = "local"

    // MARK: Session

    private func adopt(_ session: MobileSession) {
        self.session = session
        let sync = MobileSync(session: session, store: store, vault: vault)
        sync.onSessionChange = { [weak self] in self?.session = $0 }
        self.sync = sync
    }

    func signIn(email: String, password: String) async throws {
        let api = MobileSync.liveAPI(token: "")
        let fresh = try await PasswordSignIn(api: api).signIn(email: email, password: password, deviceName: UIDevice.current.name)
        await finishSignIn(fresh)
    }

    /// Stores a new session (from the password or the passwordless flow) and syncs.
    func finishSignIn(_ newSession: MobileSession) async {
        var fresh = newSession
        if let previous = session, previous.uid != fresh.uid {
            wipeAccountData()
        } else if let previous = session {
            fresh.spaceKeyPins = previous.spaceKeyPins
        }
        SessionKeychain.save(fresh)
        adopt(fresh)
        claimLocalClips()
        await syncNow()
    }

    /// Clips added while signed out join the personal space.
    private func claimLocalClips() {
        guard let personal = session?.personalSpaceId else { return }
        store.update { state in
            for index in state.clips.indices where state.clips[index].spaceId == Self.localSpace {
                state.clips[index].spaceId = personal
                state.clips[index].needsPush = true
            }
        }
    }

    /// Signs out on the server and deletes everything of the account here (PROTOCOL.md → Log out).
    /// Clips that never synced stay, as local ones.
    func signOut() async {
        await sync?.signOut()
        wipeAccountData()
        SessionKeychain.clear()
        session = nil
        sync = nil
    }

    private func wipeAccountData() {
        vault.clear()
        store.update { state in
            let keep = state.clips.filter { $0.fingerprint == nil && $0.needsPush }
            for clip in state.clips where !keep.contains(where: { $0.id == clip.id }) { MobileStore.deleteFiles(of: clip) }
            state = MobileState()
            state.clips = keep.map { var clip = $0; clip.spaceId = Self.localSpace; return clip }
        }
    }

    // MARK: Sync

    func syncNow() async {
        guard let sync, !isSyncing, session?.expired == false else { return }
        isSyncing = true
        defer { isSyncing = false }
        store.reload()
        do {
            try await sync.sync()
            errorMessage = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// While the app is in front: sync now and every `pollInterval`.
    func becameActive() {
        codes.reload()
        store.reload()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func resignedActive() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Adding

    func add(_ content: IncomingContent, options: SaveOptions = SaveOptions()) {
        do {
            let clip = try ClipImporter.makeClip(content, spaceId: personalSpaceId, options: options)
            store.add(clip, options: options)
            Task { await syncNow() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Copying

    /// Puts a clip on the clipboard: text as text, an image as PNG, files as files.
    func copy(_ clip: MobileClip) async {
        do {
            switch clip.kind {
            case .text, .richText:
                UIPasteboard.general.string = clip.payload.text ?? ""
            case .image:
                let url = try await imageFile(of: clip)
                let data = try Data(contentsOf: url)
                UIPasteboard.general.setData(data, forPasteboardType: UTType.png.identifier)
            case .file:
                let urls = try await files(of: clip)
                if urls.isEmpty {
                    UIPasteboard.general.string = clip.payload.text ?? ""
                } else {
                    UIPasteboard.general.itemProviders = urls.compactMap { NSItemProvider(contentsOf: $0) }
                }
            }
            store.markCopied(clip.id)
            show("Copied")
            Task { await syncNow() }
        } catch {
            errorMessage = "Couldn't copy: \(error.localizedDescription)"
        }
    }

    func imageFile(of clip: MobileClip) async throws -> URL {
        if let local = clip.localImage { return SharedContainer.blobsDirectory.appending(path: local) }
        guard let blob = clip.payload.imageBlob, let sync else { throw CocoaError(.fileNoSuchFile) }
        return try await sync.downloadBlob(blob, spaceId: clip.spaceId)
    }

    /// The clip's files under their names, downloaded if needed.
    func files(of clip: MobileClip) async throws -> [URL] {
        if let local = clip.localFiles {
            return local.map { SharedContainer.filesDirectory.appending(path: $0.path) }
        }
        guard let blobs = clip.payload.fileBlobs, let sync else { return [] }
        let folder = FileManager.default.temporaryDirectory.appending(path: clip.id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for blob in blobs {
            let cached = try await sync.downloadBlob(blob.blob, spaceId: clip.spaceId)
            let name = URL(filePath: blob.localName).lastPathComponent
            let named = folder.appending(path: name.isEmpty ? blob.blob : name)
            try? FileManager.default.removeItem(at: named)
            try FileManager.default.copyItem(at: cached, to: named)
            urls.append(named)
        }
        return urls
    }

    /// A password, secret or code: only on this device's clipboard, and gone after 90 seconds.
    func copySensitive(_ value: String, label: String = "Copied", source: String? = nil) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: value]],
                                      options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(90)])
        RecentSites.record(source)
        show(label)
    }

    /// Face ID / Touch ID / passcode before a password is shown or copied. Devices without a
    /// passcode can't protect anything, so they aren't asked.
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    private func show(_ message: String) {
        notice = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if self?.notice == message { self?.notice = nil }
        }
    }
}
