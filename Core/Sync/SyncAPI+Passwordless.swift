import Foundation

// MARK: - Wire types (PROTOCOL.md → Passwordless)

/// The device a passwordless session belongs to: its own P-256 key, never the account's.
nonisolated struct DeviceInfo: Codable, Sendable, Equatable {
    var publicKey: Data
    var name: String?
    var platform: String? = "macos"
}

/// `POST /v1/auth/passwordless/signup`: like `SignupRequest`, without a password or wrapped AK.
nonisolated struct PasswordlessSignupRequest: Codable, Sendable {
    var email: String?
    var googleIdToken: String?
    var username: String
    var signupCode: String?
    var groupInviteId: String?
    var uid: String
    var publicKey: Data
    var wrappedPrivateKey: Data
    var personalSpace: SignupRequest.PersonalSpace
    var device: DeviceInfo
}

/// `windowMs` is sent as `null` for indefinitely (never left out), with the acknowledgement.
nonisolated struct WindowedRequest: Encodable, Sendable {
    var identifier: String
    var method: String?
    var device: DeviceInfo
    var window: SessionWindow
    var acknowledgement: String?

    enum CodingKeys: String, CodingKey { case identifier, method, device, windowMs, acknowledgement }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identifier, forKey: .identifier)
        try c.encodeIfPresent(method, forKey: .method)
        try c.encode(device, forKey: .device)
        if let ms = window.milliseconds { try c.encode(ms, forKey: .windowMs) } else { try c.encodeNil(forKey: .windowMs) }
        if window == .indefinitely { try c.encodeIfPresent(acknowledgement, forKey: .acknowledgement) }
    }
}

/// `POST /v1/auth/device-requests`: shown to the new device, which polls with `secret`.
nonisolated struct DeviceLoginTicket: Codable, Sendable, Equatable {
    var requestId: String
    var secret: String
    var expiresAt: Int64
}

/// `POST /v1/auth/device-requests/:id/poll`. Once approved, the session and AK wrapped to this device.
nonisolated struct DeviceLoginPoll: Codable, Sendable, Equatable {
    var status: String
    var token: String?
    var expiresAt: Int64?
    var account: RemoteAccount?
    var wrappedAccountKey: Data?
}

/// `GET /v1/device-requests`: a new device asking to join this account.
nonisolated struct PendingDeviceRequest: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var deviceName: String?
    var platform: String?
    var country: String?
    var city: String?
    var newCountry: Bool?
    var windowMs: Int64?
    var devicePublicKey: Data
    var createdAt: Int64
    var expiresAt: Int64
}

nonisolated struct RecoverySetupState: Codable, Sendable, Equatable {
    nonisolated struct Contact: Codable, Sendable, Equatable, Identifiable {
        var uid: String
        var name: String
        var accepted: Bool
        var id: String { uid }
    }
    var id: String
    var method: String
    /// pending (waiting for contacts to accept) | active | broken (a contact stepped down)
    var status: String
    var createdAt: Int64
    var contacts: [Contact]
}

/// Someone asked you to be their recovery contact (or you already are).
nonisolated struct RecoveryInvitation: Codable, Sendable, Equatable, Identifiable {
    var setupId: String
    var uid: String
    var name: String
    var accepted: Bool
    var createdAt: Int64
    var id: String { setupId }
}

/// A contact of yours is recovering their account and needs your share.
nonisolated struct RecoveryHelpRequest: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var uid: String
    var name: String
    var setupId: String
    var deviceName: String?
    var platform: String?
    var country: String?
    var city: String?
    var devicePublicKey: Data
    var wrappedShare: Data
    var createdAt: Int64
    var releaseAt: Int64
    var expiresAt: Int64
}

/// A recovery of your own account in progress: any of your devices can cancel it.
nonisolated struct AccountRecovery: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var method: String
    var deviceName: String?
    var platform: String?
    var country: String?
    var city: String?
    var createdAt: Int64
    var releaseAt: Int64
    var approvals: Int
    var needed: Int
}

nonisolated struct RecoveryTicket: Codable, Sendable, Equatable {
    var recoveryId: String
    var secret: String
    var releaseAt: Int64
    var expiresAt: Int64
}

nonisolated struct RecoveryPoll: Codable, Sendable, Equatable {
    nonisolated struct Share: Codable, Sendable, Equatable {
        var uid: String
        var wrappedShare: Data
    }
    var status: String
    var releaseAt: Int64?
    var approvals: Int?
    var needed: Int?
    var token: String?
    var expiresAt: Int64?
    var account: RemoteAccount?
    var method: String?
    var setupId: String?
    var shares: [Share]?
    var escrowShare: Data?
    var wrappedSecret: Data?
}

nonisolated struct PasswordlessSwitch: Codable, Sendable, Equatable {
    var account: RemoteAccount
    var session: RemoteDevice
}

// MARK: - Service

/// Every call passwordless accounts make. Defaults answer like a server without them (`404`).
nonisolated protocol PasswordlessService: Sendable {
    func passwordlessSignup(_ body: PasswordlessSignupRequest) async throws -> RemoteSession
    func requestDeviceLogin(_ body: WindowedRequest) async throws -> DeviceLoginTicket
    func pollDeviceLogin(id: String, secret: String) async throws -> DeviceLoginPoll
    func cancelDeviceLogin(id: String, secret: String) async throws
    func deviceRequests() async throws -> [PendingDeviceRequest]
    /// Without `wrappedAccountKey` it reports a mismatch the client already saw.
    func approveDeviceRequest(id: String, number: Int, wrappedAccountKey: Data?) async throws
    func denyDeviceRequest(id: String, block: Bool) async throws
    func setSessionWindow(id: String, window: SessionWindow, acknowledgement: String?) async throws -> RemoteDevice
    func switchToPasswordless(authKey: Data, devicePublicKey: Data, retirePassword: Bool) async throws -> PasswordlessSwitch
    func setEmail(_ email: String?, googleIdToken: String?) async throws -> RemoteAccount
    func deletePasswordlessAccount(confirm: String) async throws

    func recoverySetup() async throws -> RecoverySetupState?
    func setUpRecovery(setupId: String, contacts: [(uid: String, wrappedShare: Data)], escrowShare: Data) async throws -> RecoverySetupState
    func deleteRecovery() async throws
    func recoveryInvitations() async throws -> [RecoveryInvitation]
    func acceptRecoveryInvitation(setupId: String) async throws
    func declineRecoveryInvitation(setupId: String) async throws
    func recoveryRequests() async throws -> [RecoveryHelpRequest]
    func approveRecovery(id: String, number: Int, wrappedShare: Data?) async throws
    func denyRecovery(id: String) async throws
    func accountRecoveries() async throws -> [AccountRecovery]
    func cancelAccountRecovery(id: String) async throws
    func startRecovery(_ body: WindowedRequest) async throws -> RecoveryTicket
    func pollRecovery(id: String, secret: String) async throws -> RecoveryPoll
    func cancelRecovery(id: String, secret: String) async throws
}

private func unsupported() -> SyncAPIError { .server(status: 404, code: "not_found", message: "", retryAfter: nil) }

extension SyncService {
    func passwordlessSignup(_ body: PasswordlessSignupRequest) async throws -> RemoteSession { throw unsupported() }
    func requestDeviceLogin(_ body: WindowedRequest) async throws -> DeviceLoginTicket { throw unsupported() }
    func pollDeviceLogin(id: String, secret: String) async throws -> DeviceLoginPoll { throw unsupported() }
    func cancelDeviceLogin(id: String, secret: String) async throws { throw unsupported() }
    func deviceRequests() async throws -> [PendingDeviceRequest] { throw unsupported() }
    func approveDeviceRequest(id: String, number: Int, wrappedAccountKey: Data?) async throws { throw unsupported() }
    func denyDeviceRequest(id: String, block: Bool) async throws { throw unsupported() }
    func setSessionWindow(id: String, window: SessionWindow, acknowledgement: String?) async throws -> RemoteDevice { throw unsupported() }
    func switchToPasswordless(authKey: Data, devicePublicKey: Data, retirePassword: Bool) async throws -> PasswordlessSwitch { throw unsupported() }
    func setEmail(_ email: String?, googleIdToken: String?) async throws -> RemoteAccount { throw unsupported() }
    func deletePasswordlessAccount(confirm: String) async throws { throw unsupported() }
    func recoverySetup() async throws -> RecoverySetupState? { throw unsupported() }
    func setUpRecovery(setupId: String, contacts: [(uid: String, wrappedShare: Data)], escrowShare: Data) async throws -> RecoverySetupState {
        throw unsupported()
    }
    func deleteRecovery() async throws { throw unsupported() }
    func recoveryInvitations() async throws -> [RecoveryInvitation] { throw unsupported() }
    func acceptRecoveryInvitation(setupId: String) async throws { throw unsupported() }
    func declineRecoveryInvitation(setupId: String) async throws { throw unsupported() }
    func recoveryRequests() async throws -> [RecoveryHelpRequest] { throw unsupported() }
    func approveRecovery(id: String, number: Int, wrappedShare: Data?) async throws { throw unsupported() }
    func denyRecovery(id: String) async throws { throw unsupported() }
    func accountRecoveries() async throws -> [AccountRecovery] { throw unsupported() }
    func cancelAccountRecovery(id: String) async throws { throw unsupported() }
    func startRecovery(_ body: WindowedRequest) async throws -> RecoveryTicket { throw unsupported() }
    func pollRecovery(id: String, secret: String) async throws -> RecoveryPoll { throw unsupported() }
    func cancelRecovery(id: String, secret: String) async throws { throw unsupported() }
}

// MARK: - HTTP

extension SyncAPI {
    nonisolated private struct SecretBody: Codable { var secret: String }
    nonisolated private struct RequestsBody<T: Codable>: Codable { var requests: [T] }
    nonisolated private struct ApproveBody: Codable { var number: Int; var wrappedAccountKey: Data? }
    nonisolated private struct DenyBody: Codable { var block: Bool }
    nonisolated private struct SwitchBody: Codable { var authKey: Data; var devicePublicKey: Data; var platform = "macos"; var retirePassword: Bool }
    nonisolated private struct EmailChange: Codable { var email: String?; var googleIdToken: String? }
    nonisolated private struct ConfirmBody: Codable { var confirm: String }
    nonisolated private struct SetupBody: Codable { var setup: RecoverySetupState? }
    nonisolated private struct ContactShare: Codable { var uid: String; var wrappedShare: Data }
    nonisolated private struct RecoveryBody: Codable {
        var method = "contacts"
        var setupId: String
        var contacts: [ContactShare]
        var escrowShare: Data
    }
    nonisolated private struct InvitationsBody: Codable { var invitations: [RecoveryInvitation] }
    nonisolated private struct RecoveriesBody: Codable { var recoveries: [AccountRecovery] }
    nonisolated private struct ShareApproval: Codable { var number: Int; var wrappedShare: Data? }

    /// `windowMs` must be present (null for indefinitely), so it's encoded by hand.
    nonisolated private struct WindowBody: Encodable {
        var window: SessionWindow
        var acknowledgement: String?
        enum CodingKeys: String, CodingKey { case windowMs, acknowledgement }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let ms = window.milliseconds { try c.encode(ms, forKey: .windowMs) } else { try c.encodeNil(forKey: .windowMs) }
            if window == .indefinitely { try c.encodeIfPresent(acknowledgement, forKey: .acknowledgement) }
        }
    }

    private static func path(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? id
    }

    func passwordlessSignup(_ body: PasswordlessSignupRequest) async throws -> RemoteSession {
        try await send("POST", "v1/auth/passwordless/signup", body: body, as: RemoteSession.self, authenticated: false)
    }

    func requestDeviceLogin(_ body: WindowedRequest) async throws -> DeviceLoginTicket {
        try await send("POST", "v1/auth/device-requests", body: body, as: DeviceLoginTicket.self, authenticated: false)
    }

    func pollDeviceLogin(id: String, secret: String) async throws -> DeviceLoginPoll {
        try await send("POST", "v1/auth/device-requests/\(Self.path(id))/poll", body: SecretBody(secret: secret),
                       as: DeviceLoginPoll.self, authenticated: false)
    }

    func cancelDeviceLogin(id: String, secret: String) async throws {
        _ = try await send("POST", "v1/auth/device-requests/\(Self.path(id))/cancel", body: SecretBody(secret: secret),
                           as: Empty.self, authenticated: false)
    }

    func deviceRequests() async throws -> [PendingDeviceRequest] {
        try await send("GET", "v1/device-requests", as: RequestsBody<PendingDeviceRequest>.self).requests
    }

    func approveDeviceRequest(id: String, number: Int, wrappedAccountKey: Data?) async throws {
        _ = try await send("POST", "v1/device-requests/\(Self.path(id))/approve",
                           body: ApproveBody(number: number, wrappedAccountKey: wrappedAccountKey), as: Empty.self)
    }

    func denyDeviceRequest(id: String, block: Bool) async throws {
        _ = try await send("POST", "v1/device-requests/\(Self.path(id))/deny", body: DenyBody(block: block), as: Empty.self)
    }

    func setSessionWindow(id: String, window: SessionWindow, acknowledgement: String?) async throws -> RemoteDevice {
        try await send("PATCH", "v1/sessions/\(Self.path(id))", body: WindowBody(window: window, acknowledgement: acknowledgement),
                       as: RemoteDevice.self)
    }

    func switchToPasswordless(authKey: Data, devicePublicKey: Data, retirePassword: Bool) async throws -> PasswordlessSwitch {
        try await send("POST", "v1/account/passwordless",
                       body: SwitchBody(authKey: authKey, devicePublicKey: devicePublicKey, retirePassword: retirePassword),
                       as: PasswordlessSwitch.self)
    }

    func setEmail(_ email: String?, googleIdToken: String?) async throws -> RemoteAccount {
        try await send("PUT", "v1/account/email", body: EmailChange(email: email, googleIdToken: googleIdToken), as: RemoteAccount.self)
    }

    func deletePasswordlessAccount(confirm: String) async throws {
        _ = try await send("DELETE", "v1/account", body: ConfirmBody(confirm: confirm), as: Empty.self)
    }

    func recoverySetup() async throws -> RecoverySetupState? {
        try await send("GET", "v1/account/recovery", as: SetupBody.self).setup
    }

    func setUpRecovery(setupId: String, contacts: [(uid: String, wrappedShare: Data)], escrowShare: Data) async throws -> RecoverySetupState {
        let body = RecoveryBody(setupId: setupId, contacts: contacts.map { ContactShare(uid: $0.uid, wrappedShare: $0.wrappedShare) },
                                escrowShare: escrowShare)
        guard let setup = try await send("PUT", "v1/account/recovery", body: body, as: SetupBody.self).setup else {
            throw SyncAPIError.invalidResponse
        }
        return setup
    }

    func deleteRecovery() async throws {
        _ = try await send("DELETE", "v1/account/recovery", as: Empty.self)
    }

    func recoveryInvitations() async throws -> [RecoveryInvitation] {
        try await send("GET", "v1/recovery/invitations", as: InvitationsBody.self).invitations
    }

    func acceptRecoveryInvitation(setupId: String) async throws {
        _ = try await send("POST", "v1/recovery/invitations/\(Self.path(setupId))/accept", body: Empty(), as: Empty.self)
    }

    func declineRecoveryInvitation(setupId: String) async throws {
        _ = try await send("DELETE", "v1/recovery/invitations/\(Self.path(setupId))", as: Empty.self)
    }

    func recoveryRequests() async throws -> [RecoveryHelpRequest] {
        try await send("GET", "v1/recovery/requests", as: RequestsBody<RecoveryHelpRequest>.self).requests
    }

    func approveRecovery(id: String, number: Int, wrappedShare: Data?) async throws {
        _ = try await send("POST", "v1/recovery/requests/\(Self.path(id))/approve",
                           body: ShareApproval(number: number, wrappedShare: wrappedShare), as: Empty.self)
    }

    func denyRecovery(id: String) async throws {
        _ = try await send("POST", "v1/recovery/requests/\(Self.path(id))/deny", body: Empty(), as: Empty.self)
    }

    func accountRecoveries() async throws -> [AccountRecovery] {
        try await send("GET", "v1/account/recoveries", as: RecoveriesBody.self).recoveries
    }

    func cancelAccountRecovery(id: String) async throws {
        _ = try await send("POST", "v1/account/recoveries/\(Self.path(id))/cancel", body: Empty(), as: Empty.self)
    }

    func startRecovery(_ body: WindowedRequest) async throws -> RecoveryTicket {
        try await send("POST", "v1/auth/recovery", body: body, as: RecoveryTicket.self, authenticated: false)
    }

    func pollRecovery(id: String, secret: String) async throws -> RecoveryPoll {
        try await send("POST", "v1/auth/recovery/\(Self.path(id))/poll", body: SecretBody(secret: secret),
                       as: RecoveryPoll.self, authenticated: false)
    }

    func cancelRecovery(id: String, secret: String) async throws {
        _ = try await send("POST", "v1/auth/recovery/\(Self.path(id))/cancel", body: SecretBody(secret: secret),
                           as: Empty.self, authenticated: false)
    }
}
