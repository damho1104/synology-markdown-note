import Foundation
import SwiftSoup

public struct RemoteNotebook: Codable, Sendable {
    public var id: String
    public var name: String
    public var stack: String
    public init(id: String, name: String, stack: String = "") {
        self.id = id; self.name = name; self.stack = stack
    }
}

public struct RemoteNoteSummary: Codable, Sendable {
    public var id: String
    public var title: String
    public var notebookID: String
    public var version: String
    public var createdAt: Date?
    public var modifiedAt: Date
    public var tags: [String]
    public var isFavorite: Bool
    public var isTrashed: Bool
    public var isLocked: Bool
    public init(id: String, title: String, notebookID: String, version: String, modifiedAt: Date, createdAt: Date? = nil,
                tags: [String] = [], isFavorite: Bool = false, isTrashed: Bool = false, isLocked: Bool = false) {
        self.id = id; self.title = title; self.notebookID = notebookID; self.version = version
        self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.tags = tags; self.isFavorite = isFavorite
        self.isTrashed = isTrashed; self.isLocked = isLocked
    }
}

public struct RemoteAttachment: Codable, Sendable {
    public var id: String
    public var name: String
    public var mimeType: String?
    public var reference: String?
    public init(id: String, name: String, mimeType: String? = nil, reference: String? = nil) {
        self.id = id; self.name = name; self.mimeType = mimeType
        self.reference = reference
    }
}

public struct RemoteNote: Codable, Sendable {
    public var summary: RemoteNoteSummary
    public var html: String
    public var attachments: [RemoteAttachment]
    public init(summary: RemoteNoteSummary, html: String, attachments: [RemoteAttachment] = []) {
        self.summary = summary; self.html = html; self.attachments = attachments
    }
}

public struct RemoteRevision: Codable, Sendable {
    public var version: String
    public var title: String?
    public var modifiedAt: Date
    public init(version: String, title: String? = nil, modifiedAt: Date) {
        self.version = version; self.title = title; self.modifiedAt = modifiedAt
    }
}

public struct WriteValidationReceipt: Codable, Sendable, Equatable {
    public var objectID: String
    public var version: String
    public var title: String
    public var notebookID: String
    public init(objectID: String, version: String, title: String, notebookID: String) {
        self.objectID = objectID
        self.version = version
        self.title = title
        self.notebookID = notebookID
    }
}

public struct NoteStationCapabilities: Codable, Sendable {
    public let supportsReads: Bool
    public let supportsWrites: Bool
    public let supportsEncryptedNotes: Bool
}

/// Values never include request URLs, credentials, SIDs, or server response bodies.
public enum NoteStationError: Error, Equatable, Sendable {
    case invalidBaseURL
    case insecureTransport
    case invalidArgument(String)
    case notConnected
    case connectionChanged
    case unsupportedAPI(String)
    case authenticationFailed(code: Int)
    case otpRequired
    case invalidOTP
    case sessionExpired
    case permissionDenied
    case lockedNote
    case http(status: Int)
    case transport(code: Int)
    case cancelled
    case api(code: Int)
    case invalidResponse
    case writeContractUnvalidated
    case versionConflict
    case validationInProgress
    case notebookWriteUncertain(objectID: String?)
    case stackWriteUncertain
}

public actor NoteStationClient {
    public nonisolated let capabilities: NoteStationCapabilities
    private let baseURL: URL
    private let session: URLSession
    private var generation = UUID()
    private var sid: String?
    private var apiInfo: [String: APIInfo] = [:]
    private var summaries: [String: RemoteNoteSummary] = [:]
    private var editingValidationInProgress = false
    private var pendingNotebookCreates: [String: String] = [:]
    private var stackMutationInProgress = false
    public var isAuthenticated: Bool { sid != nil }
    public private(set) var trustedDeviceID: String?
    private static let noteAPI = "SYNO.NoteStation.Note"

    public init(baseURL: URL, session: URLSession = .shared, allowsValidatedWrites: Bool = false) {
        self.baseURL = baseURL
        self.session = session
        capabilities = NoteStationCapabilities(supportsReads: true, supportsWrites: allowsValidatedWrites, supportsEncryptedNotes: false)
    }

    /// Explicit credentials only. Passwords and OTPs are not retained or automatically retried.
    public func connect(username: String, password: String, otp: String? = nil,
                        rememberDevice: Bool = false, deviceID: String? = nil) async throws {
        disconnect()
        let attempt = generation
        try validateBaseURL()
        try requireIdentifier(username, name: "username")
        let authAPI = "SYNO.API.Auth"
        do {
            let discovery = try await query("SYNO.API.Auth", sid: nil, generation: attempt)
            guard let auth = discovery[authAPI], auth.maxVersion >= auth.minVersion else {
                throw NoteStationError.unsupportedAPI(authAPI)
            }
            // DSM recommends v6, and the installed official client caps login
            // at v6 even when discovery advertises v7. Use its device-token
            // contract rather than assuming the newest version is equivalent.
            let authVersion = max(auth.minVersion, min(auth.maxVersion, 6))
            var params = ["account": username, "passwd": password, "session": "notestation", "format": "sid"]
            if let otp, !otp.isEmpty { params["otp_code"] = otp }
            if rememberDevice, authVersion >= 6 {
                params["device_name"] = "SynologyNote macOS"
                params["enable_device_token"] = "yes"
                // A newly supplied OTP registers a fresh token rather than
                // recycling a revoked device identity.
                if params["otp_code"] == nil, let deviceID, !deviceID.isEmpty { params["device_id"] = deviceID }
            }
            let login = try makeRequest(api: authAPI, method: "login", version: authVersion,
                                        info: auth, params: params, sid: nil, raw: true)
            let (bytes, _) = try await send(login, generation: attempt)
            let data = try responseData(bytes, authentication: true)
            guard let newSID = data["sid"] as? String, !newSID.isEmpty else { throw NoteStationError.invalidResponse }
            // The original app performs its complete API discovery after authentication.
            let discovered = try await query("all", sid: newSID, generation: attempt)
            guard discovered[Self.noteAPI] != nil else { throw NoteStationError.unsupportedAPI(Self.noteAPI) }
            apiInfo = discovered
            sid = newSID
            if rememberDevice, authVersion >= 6 {
                let returned = data["did"] as? String
                trustedDeviceID = returned.flatMap { $0.isEmpty ? nil : $0 } ?? params["device_id"]
            }
        } catch {
            if generation == attempt { sid = nil; apiInfo = [:]; summaries = [:] }
            throw error
        }
    }

    /// Drops this actor's session locally. Does not invalidate the injected URLSession or send a server write.
    public func disconnect() {
        generation = UUID()
        sid = nil
        apiInfo = [:]
        summaries = [:]
        trustedDeviceID = nil
    }

    public func notebooks() async throws -> [RemoteNotebook] {
        let rows = try await list(api: "SYNO.NoteStation.Notebook", cap: 2, minimum: 2, key: "notebooks", identity: "object_id")
        return try rows.map { row in
            let stack: String
            if row["stack"] == nil || row["stack"] is NSNull { stack = "" }
            else { stack = try string(row, "stack", allowEmpty: true) }
            return RemoteNotebook(id: try string(row, "object_id"), name: try string(row, "title", allowEmpty: true), stack: stack)
        }
    }

    /// Stack membership is a server-side Notebook attribute. A stack is first
    /// created by assigning at least one notebook to its name.
    public func moveNotebooksToStack(ids: [String], name: String, creatingNew: Bool = false) async throws -> [RemoteNotebook] {
        guard capabilities.supportsWrites else { throw NoteStationError.writeContractUnvalidated }
        guard !ids.isEmpty, Set(ids).count == ids.count else { throw NoteStationError.invalidArgument("notebookIDs") }
        for id in ids { try requireIdentifier(id, name: "notebookID") }
        guard name == name.trimmingCharacters(in: .whitespacesAndNewlines) else { throw NoteStationError.invalidArgument("stack name") }
        try beginStackMutation()
        defer { stackMutationInProgress = false }
        let attempt = generation
        let before = try await notebooks()
        try requireValidationConnection(attempt)
        guard !creatingNew || (!name.isEmpty && !before.contains(where: { $0.stack == name })) else {
            throw NoteStationError.invalidArgument("duplicate stack name")
        }
        let requested = Set(ids)
        guard requested.isSubset(of: Set(before.map(\.id))) else { throw NoteStationError.invalidArgument("notebookIDs") }
        if before.filter({ requested.contains($0.id) }).allSatisfy({ $0.stack == name }) { return before }
        do {
            _ = try await request(api: "SYNO.NoteStation.Notebook", method: "set", cap: 2, minimum: 2,
                params: ["object_id": ids, "stack": name, "commit_msg": ["device": "desktop"]], allowsEmptyData: true)
        } catch {
            if isDefinitiveStackFailure(error) { throw error }
            if let confirmed = try? await verifiedStackMembership(ids: requested, name: name, attempt: attempt) { return confirmed }
            throw NoteStationError.stackWriteUncertain
        }
        return try await verifiedStackMembership(ids: requested, name: name, attempt: attempt)
    }

    public func renameStack(from oldName: String, to name: String) async throws -> [RemoteNotebook] {
        guard capabilities.supportsWrites else { throw NoteStationError.writeContractUnvalidated }
        try requireIdentifier(oldName, name: "oldStack")
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try requireIdentifier(name, name: "stackName")
        try beginStackMutation()
        defer { stackMutationInProgress = false }
        let attempt = generation
        let books = try await notebooks()
        try requireValidationConnection(attempt)
        let members = Set(books.filter { $0.stack == oldName }.map(\.id))
        guard !members.isEmpty else { throw NoteStationError.invalidArgument("oldStack") }
        guard oldName != name else { return books }
        guard !books.contains(where: { $0.stack == name }) else { throw NoteStationError.invalidArgument("duplicate stack name") }
        let id = try await stackID(for: oldName, attempt: attempt)
        do {
            _ = try await request(api: "SYNO.NoteStation.Stack", method: "set", cap: 1, minimum: 1,
                params: ["stack_id": id, "name": name], allowsEmptyData: true)
        } catch {
            if isDefinitiveStackFailure(error) { throw error }
            if let confirmed = try? await verifiedStackRename(oldName: oldName, members: members, name: name, attempt: attempt) { return confirmed }
            throw NoteStationError.stackWriteUncertain
        }
        return try await verifiedStackRename(oldName: oldName, members: members, name: name, attempt: attempt)
    }

    /// Stack deletion only clears grouping; notebooks and their notes survive.
    public func deleteStack(name: String) async throws -> [RemoteNotebook] {
        guard capabilities.supportsWrites else { throw NoteStationError.writeContractUnvalidated }
        try requireIdentifier(name, name: "stackName")
        try beginStackMutation()
        defer { stackMutationInProgress = false }
        let attempt = generation
        let books = try await notebooks()
        try requireValidationConnection(attempt)
        let members = Set(books.filter { $0.stack == name }.map(\.id))
        guard !members.isEmpty else { throw NoteStationError.invalidArgument("stackName") }
        let id = try await stackID(for: name, attempt: attempt)
        do {
            _ = try await request(api: "SYNO.NoteStation.Stack", method: "delete", cap: 1, minimum: 1,
                params: ["stack_id": id], allowsEmptyData: true)
        } catch {
            if isDefinitiveStackFailure(error) { throw error }
            if let confirmed = try? await verifiedStackMembership(ids: members, name: "", attempt: attempt) { return confirmed }
            throw NoteStationError.stackWriteUncertain
        }
        return try await verifiedStackMembership(ids: members, name: "", attempt: attempt)
    }

    private func beginStackMutation() throws {
        guard !stackMutationInProgress else { throw NoteStationError.validationInProgress }
        stackMutationInProgress = true
    }

    private func isDefinitiveStackFailure(_ error: Error) -> Bool {
        guard let error = error as? NoteStationError else { return false }
        switch error {
        case .api, .permissionDenied, .sessionExpired, .authenticationFailed,
             .unsupportedAPI, .notConnected, .connectionChanged, .invalidArgument,
             .writeContractUnvalidated, .versionConflict, .invalidBaseURL, .insecureTransport:
            return true
        default: return false
        }
    }

    private func stackID(for name: String, attempt: UUID) async throws -> String {
        // Official client initial() reads result[1] of Info/get v2 for owner_uid.
        let info = try await request(api: "SYNO.NoteStation.Info", method: "get", cap: 2, minimum: 2)
        try requireValidationConnection(attempt)
        let uid: String
        if let number = info["uid"] as? NSNumber { uid = number.stringValue }
        else if let value = info["uid"] as? String, !value.isEmpty { uid = value }
        else { throw NoteStationError.invalidResponse }
        return "\(name)#\(uid)"
    }

    private func verifiedStackMembership(ids: Set<String>, name: String, attempt: UUID) async throws -> [RemoteNotebook] {
        let result = try await notebooks()
        try requireValidationConnection(attempt)
        guard ids.allSatisfy({ id in result.contains { $0.id == id && $0.stack == name } }) else {
            throw NoteStationError.stackWriteUncertain
        }
        return result
    }

    private func verifiedStackRename(oldName: String, members: Set<String>, name: String, attempt: UUID) async throws -> [RemoteNotebook] {
        // Stack/set can become visible in Notebook/list a little later than its
        // success response. Retry *reads* only: repeating the write could rename
        // another stack or overwrite a concurrent change.
        for check in 0..<6 {
            try Task.checkCancellation()
            try requireValidationConnection(attempt)
            do {
                let result = try await notebooks()
                try requireValidationConnection(attempt)
                if members.allSatisfy({ id in result.contains { $0.id == id && $0.stack == name } }),
                   !result.contains(where: { $0.stack == oldName }) {
                    return result
                }
            } catch {
                try Task.checkCancellation()
                try requireValidationConnection(attempt)
                // The mutation may already have succeeded; a failed readback
                // does not authorize a second Stack/set request.
            }
            if check < 5 { try await Task.sleep(for: .milliseconds(400)) }
        }
        throw NoteStationError.stackWriteUncertain
    }

    /// Installed official Storage.WebAPI createNotebook/setNotebook use v2.
    /// No server idempotency key or notebook conflict-check contract is known.
    /// An ambiguous create is retained and never repeated by this client.
    public func createNotebook(name: String) async throws -> RemoteNotebook {
        guard capabilities.supportsWrites else { throw NoteStationError.writeContractUnvalidated }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try requireIdentifier(name, name: "name")
        guard sid != nil else { throw NoteStationError.notConnected }
        let attempt = generation
        if let pending = pendingNotebookCreates[name] {
            guard !pending.isEmpty else { throw NoteStationError.notebookWriteUncertain(objectID: nil) }
            do {
                let books = try await notebooks()
                try requireValidationConnection(attempt)
                guard let confirmed = books.first(where: { $0.id == pending && $0.name == name }) else { throw NoteStationError.invalidResponse }
                pendingNotebookCreates.removeValue(forKey: name)
                return confirmed
            } catch { throw NoteStationError.notebookWriteUncertain(objectID: pending) }
        }
        let existing = try await notebooks()
        try requireValidationConnection(attempt)
        // Recheck after suspension: another caller may have begun a create.
        guard pendingNotebookCreates[name] == nil else { throw NoteStationError.notebookWriteUncertain(objectID: nil) }
        guard !existing.contains(where: { $0.name == name }) else { throw NoteStationError.invalidArgument("duplicate notebook name") }
        _ = try supported("SYNO.NoteStation.Notebook", cap: 2, minimum: 2)
        pendingNotebookCreates[name] = ""
        var acknowledgedID: String?
        do {
            let row = try await request(api: "SYNO.NoteStation.Notebook", method: "create", cap: 2, minimum: 2,
                params: ["title": name, "commit_msg": ["device": "desktop"]])
            let id = try string(row, "object_id")
            acknowledgedID = id; pendingNotebookCreates[name] = id
            let books = try await notebooks()
            try requireValidationConnection(attempt)
            guard let confirmed = books.first(where: { $0.id == id && $0.name == name }) else { throw NoteStationError.invalidResponse }
            pendingNotebookCreates.removeValue(forKey: name)
            return confirmed
        } catch {
            // A typed API rejection proves the create was rejected. Any failure
            // after acknowledgement is a readback uncertainty instead.
            if acknowledgedID == nil, let failure = error as? NoteStationError {
                switch failure {
                case .api, .permissionDenied, .sessionExpired, .unsupportedAPI, .notConnected, .invalidArgument:
                    pendingNotebookCreates.removeValue(forKey: name)
                    throw failure
                default: break
                }
            }
            throw NoteStationError.notebookWriteUncertain(objectID: acknowledgedID)
        }
    }

    public func renameNotebook(notebookID: String, name: String) async throws -> RemoteNotebook {
        guard capabilities.supportsWrites else { throw NoteStationError.writeContractUnvalidated }
        try requireIdentifier(notebookID, name: "notebookID")
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try requireIdentifier(name, name: "name")
        let attempt = generation
        let row = try await request(api: "SYNO.NoteStation.Notebook", method: "set", cap: 2, minimum: 2,
            params: ["object_id": notebookID, "title": name, "commit_msg": ["device": "desktop"]], allowsEmptyData: true)
        // NAS versions also return success-only or a nested set receipt. The
        // target ID is already known; readback is the completion authority.
        if let value = row["object_id"] {
            guard let id = value as? String, id == notebookID else { throw NoteStationError.invalidResponse }
        }
        let books = try await notebooks()
        try requireValidationConnection(attempt)
        guard let confirmed = books.first(where: { $0.id == notebookID && $0.name == name }) else { throw NoteStationError.invalidResponse }
        return confirmed
    }

    /// Official Storage.WebAPI.deleteNotebook uses v2 with recursive=false
    /// to retain contained notes in the NAS recycle bin.
    public func deleteNotebook(notebookID: String) async throws {
        guard capabilities.supportsWrites else { throw NoteStationError.writeContractUnvalidated }
        try requireIdentifier(notebookID, name: "notebookID")
        guard sid != nil else { throw NoteStationError.notConnected }
        let attempt = generation
        let existing = try await notebooks()
        try requireValidationConnection(attempt)
        guard existing.contains(where: { $0.id == notebookID }) else { return }
        do {
            _ = try await request(api: "SYNO.NoteStation.Notebook", method: "delete", cap: 2, minimum: 2,
                params: ["object_id": notebookID, "recursive": false], allowsEmptyData: true)
        } catch {
            // A lost receipt is reconciled by reads, never by repeating delete.
            guard !(try await notebooks()).contains(where: { $0.id == notebookID }) else { throw error }
            try requireValidationConnection(attempt)
            return
        }
        let books = try await notebooks()
        try requireValidationConnection(attempt)
        guard !books.contains(where: { $0.id == notebookID }) else { throw NoteStationError.invalidResponse }
    }

    /// Official deleteNoteAsync: v3 delete, recycle=false means permanent.
    public func permanentlyDeleteNote(noteID: String, baseVersion: String) async throws {
        guard capabilities.supportsWrites else { throw NoteStationError.writeContractUnvalidated }
        try requireIdentifier(noteID, name: "noteID")
        let attempt = generation
        let listed = try await notes()
        try requireValidationConnection(attempt)
        guard let current = listed.first(where: { $0.id == noteID }) else { return }
        guard current.isTrashed else { throw NoteStationError.invalidArgument(coreText("Only notes in the Trash can be permanently deleted")) }
        guard current.version == baseVersion else { throw NoteStationError.versionConflict }
        do {
            _ = try await request(api: Self.noteAPI, method: "delete", cap: 3, minimum: 3,
                params: ["object_id": noteID, "recycle": false], allowsEmptyData: true)
        } catch {
            if let failure = error as? NoteStationError {
                switch failure {
                case .api, .permissionDenied, .sessionExpired, .authenticationFailed, .notConnected, .invalidArgument: throw failure
                default: break
                }
            }
            guard !(try await notes()).contains(where: { $0.id == noteID }) else { throw error }
            try requireValidationConnection(attempt)
            summaries.removeValue(forKey: noteID)
            return
        }
        let remaining = try await notes()
        try requireValidationConnection(attempt)
        guard !remaining.contains(where: { $0.id == noteID }) else { throw NoteStationError.invalidResponse }
        summaries.removeValue(forKey: noteID)
    }

    /// Completes every page and the shortcut read before publishing a new metadata snapshot.
    public func notes() async throws -> [RemoteNoteSummary] {
        let attempt = generation
        let rows = try await list(api: Self.noteAPI, cap: 3, minimum: 2, key: "notes", identity: "object_id")
        let favorites = try await favoriteIDs()
        var tagsByID: [String: [String]] = [:]
        if rows.contains(where: { $0["tag"] == nil }), apiInfo["SYNO.NoteStation.Tag"] != nil {
            let tags = try await list(api: "SYNO.NoteStation.Tag", cap: 1, minimum: 1, key: "tags", identity: "tag_id")
            for tag in tags {
                let title = try string(tag, "title", allowEmpty: true)
                guard let items = tag["items"] as? [String] else { throw NoteStationError.invalidResponse }
                for id in items { tagsByID[id, default: []].append(title) }
            }
        }
        let result = try rows.map { row -> RemoteNoteSummary in
            var row = row
            let id = try string(row, "object_id")
            if row["tag"] == nil { row["tag"] = tagsByID[id] ?? [] }
            return try summary(row, fallback: nil, favorite: favorites.contains(id))
        }
        guard generation == attempt, sid != nil else { throw NoteStationError.connectionChanged }
        summaries = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        return result
    }

    public func fetch(noteID: String) async throws -> RemoteNote {
        try requireIdentifier(noteID, name: "noteID")
        if summaries[noteID]?.isLocked == true { throw NoteStationError.lockedNote }
        let attempt = generation
        var row = try await request(api: Self.noteAPI, method: "get", cap: 3, minimum: 2, params: ["object_id": noteID])
        // The installed client's response adapter also restores the requested object_id.
        if row["object_id"] == nil { row["object_id"] = noteID }
        guard try string(row, "object_id") == noteID else { throw NoteStationError.invalidResponse }
        if try flag(row, "encrypt") == true { throw NoteStationError.lockedNote }
        var fallback = summaries[noteID]
        if fallback == nil && ["parent_id", "tag", "encrypt", "recycle"].contains(where: { row[$0] == nil }) {
            fallback = try await notes().first { $0.id == noteID }
        }
        let favorite: Bool
        if let fallback { favorite = fallback.isFavorite }
        else { favorite = try await favoriteIDs().contains(noteID) }
        let metadata = try summary(row, fallback: fallback, favorite: favorite)
        guard !metadata.isLocked else { throw NoteStationError.lockedNote }
        let html = try string(row, "content", allowEmpty: true)
        var attachments: [RemoteAttachment] = []
        if let value = row["attachment"], !(value is NSNull) {
            guard let files = value as? [String: [String: Any]] else { throw NoteStationError.invalidResponse }
            attachments = try files.keys.sorted().map { id in
                let file = files[id]!
                if let type = file["type"], !(type is NSNull), !(type is String) { throw NoteStationError.invalidResponse }
                if let reference = file["ref"], !(reference is NSNull), !(reference is String) { throw NoteStationError.invalidResponse }
                return RemoteAttachment(id: id, name: try string(file, "name", allowEmpty: true), mimeType: file["type"] as? String, reference: file["ref"] as? String)
            }
        }
        guard generation == attempt, sid != nil else { throw NoteStationError.connectionChanged }
        return RemoteNote(summary: metadata, html: html, attachments: attachments)
    }

    public func versionHistory(noteID: String) async throws -> [RemoteRevision] {
        try requireIdentifier(noteID, name: "noteID")
        let rows = try await list(api: "SYNO.NoteStation.Note.Version", cap: 2, minimum: 2,
                                  key: "versions", identity: "version", params: ["object_id": noteID, "filter": ["listable": true]])
        return try rows.map { row in
            RemoteRevision(version: try string(row, "version"), title: nil, modifiedAt: try date(row, "mtime"))
        }
    }

    /// Downloads the original file, never the thumbnail. Encrypted-note tokens are deliberately unsupported.
    public func download(fileID: String, noteID: String) async throws -> Data {
        try requireIdentifier(fileID, name: "fileID")
        try requireIdentifier(noteID, name: "noteID")
        if summaries[noteID]?.isLocked == true { throw NoteStationError.lockedNote }
        guard let sid else { throw NoteStationError.notConnected }
        let info = try supported(Self.noteAPI, cap: 1, minimum: 1)
        let req = try makeRequest(api: Self.noteAPI, method: "download", version: info.version, info: info.info,
                                  params: ["file_id": fileID, "object_id": noteID, "format": "raw", "mode": "download"], sid: sid)
        let (bytes, response) = try await send(req, generation: generation)
        // A file may itself be JSON. Only a Synology error envelope is classified as an API failure.
        if let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           object["success"] as? Bool == false, let error = object["error"] as? [String: Any], let code = error["code"] as? Int {
            throw apiError(code, authentication: false)
        }
        if response.mimeType?.lowercased() == "application/json",
           let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], object["success"] as? Bool == false {
            throw NoteStationError.invalidResponse
        }
        return bytes
    }

    /// Validation-only real NAS write. This is deliberately separate from the
    /// production sync transport and does not make `supportsWrites` true.
    /// The caller must surface an explicit confirmation before invoking it.
    public func createValidationNote(notebookID: String, title: String, html: String) async throws -> WriteValidationReceipt {
        try requireIdentifier(notebookID, name: "notebookID")
        try requireIdentifier(title, name: "title")
        guard !html.isEmpty else { throw NoteStationError.invalidArgument("html") }
        let timestamp = Int(Date().timeIntervalSince1970)
        let data = try await request(api: Self.noteAPI, method: "create", cap: 3, minimum: 2, params: [
            "title": title,
            "parent_id": notebookID,
            "encrypt": false,
            "content": html,
            "brief": "SynologyNote 쓰기 호환성 검증",
            "ctime": timestamp,
            "mtime": timestamp,
            "latitude": 0,
            "longitude": 0,
            "commit_msg": ["device": "desktop", "listable": false] as [String: Any]
        ])
        return WriteValidationReceipt(objectID: try string(data, "object_id"),
                                      version: try string(data, "ver"),
                                      title: title,
                                      notebookID: notebookID)
    }

    /// A single explicit probe creates its own target. No caller-supplied note ID
    /// or title-prefix search can authorize modifying an existing user note.
    public func validateNoteEditing(notebookID: String) async throws -> NoteEditingValidationReport {
        guard !editingValidationInProgress else { throw NoteStationError.validationInProgress }
        editingValidationInProgress = true
        defer { editingValidationInProgress = false }
        let attempt = generation
        let marker = UUID().uuidString.lowercased()
        let title = "[SynologyNote 검증] 수정·충돌 \(marker)"
        let original = "<p>SynologyNote validation \(marker) initial</p>"
        let updated = "<p>SynologyNote validation \(marker) updated</p>"
        let stale = "<p>SynologyNote validation \(marker) stale</p>"
        // Never retry a write automatically, including when its response is lost.
        let receipt = try await createValidationNote(notebookID: notebookID, title: title, html: original)
        var report = NoteEditingValidationReport(receipt: receipt)
        do {
            try requireValidationConnection(attempt)
            let initial = try await fetch(noteID: receipt.objectID)
            guard initial.summary.title == title, initial.summary.notebookID == notebookID,
                  initial.summary.version == receipt.version, initial.html == original,
                  !initial.summary.isTrashed, initial.attachments.isEmpty else {
                throw NoteStationError.invalidResponse
            }
            report.stage = .update
            try requireValidationConnection(attempt)
            let version = try await setValidationNote(receipt: receipt, baseVersion: receipt.version, html: updated)
            report.updatedVersion = version
            report.stage = .updateRead
            try requireValidationConnection(attempt)
            let readback = try await fetch(noteID: receipt.objectID)
            guard version != receipt.version, readback.summary.version == version,
                  readback.summary.title == title, readback.summary.notebookID == notebookID,
                  readback.html == updated, !readback.summary.isTrashed,
                  readback.attachments.isEmpty else { throw NoteStationError.invalidResponse }
            report.updateConfirmed = true
            report.stage = .staleWrite
            try requireValidationConnection(attempt)
            do {
                _ = try await setValidationNote(receipt: receipt, baseVersion: receipt.version, html: stale)
                report.failure = coreText("The server accepted a write request with an older version.")
            } catch NoteStationError.versionConflict {
                report.conflictRejected = true
            } catch {
                report.failure = coreText("Could not confirm that the conflicting write was rejected: ") + error.localizedDescription
            }
            report.stage = .conflictRead
            try requireValidationConnection(attempt)
            let latest = try await fetch(noteID: receipt.objectID)
            report.latestContentPreserved = latest.summary.version == version && latest.html == updated
                && latest.summary.title == title && latest.summary.notebookID == notebookID
                && !latest.summary.isTrashed && latest.attachments.isEmpty
            if !report.latestContentPreserved {
                report.failure = coreText("The latest content or version changed after the attempted write with an older version.")
            }
            if report.conflictRejected && report.latestContentPreserved && report.failure == nil {
                report.stage = .completed
            }
        } catch {
            // Preserve the target ID and stage even after a timeout or malformed
            // response so the user can reconcile on NAS before running again.
            report.failure = error.localizedDescription
        }
        return report
    }

    /// Uploads only synthetic assets to a freshly created probe note. Image and
    /// source use separate version-checked writes so the source fingerprint is
    /// calculated from the canonical server HTML, not guessed normalization.
    public func validateNoteAttachments(notebookID: String) async throws -> NoteAttachmentValidationReport {
        guard !editingValidationInProgress else { throw NoteStationError.validationInProgress }
        editingValidationInProgress = true
        defer { editingValidationInProgress = false }
        let attempt = generation
        let documentID = UUID(), imageID = UUID()
        let title = "[SynologyNote 검증] 첨부·Markdown \(documentID.uuidString.lowercased())"
        let original = "<p>SynologyNote attachment validation \(documentID)</p>"
        let receipt = try await createValidationNote(notebookID: notebookID, title: title, html: original)
        var report = NoteAttachmentValidationReport(receipt: receipt)
        do {
            try requireValidationConnection(attempt)
            let initial = try await fetch(noteID: receipt.objectID)
            guard initial.html == original, initial.summary.version == receipt.version,
                  initial.summary.title == title, initial.summary.notebookID == notebookID,
                  !initial.summary.isTrashed, initial.attachments.isEmpty else { throw NoteStationError.invalidResponse }
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQzrvzH4QZYAwAUT4JsSqASqYAAAAASUVORK5CYII=")!
            let imageName = "synology-note-probe-\(imageID.uuidString).png"
            let html = "<h2>Markdown attachment validation</h2><p><img ref=\"\(imageID.uuidString)\" alt=\"검증 이미지\"></p>"
            report.stage = .imageUpload
            try requireValidationConnection(attempt)
            let imageVersion = try await uploadValidationAttachment(receipt: receipt, baseVersion: receipt.version,
                html: html, filename: imageName, mimeType: "image/png", bytes: png, reference: imageID.uuidString)
            report.stage = .imageRead
            try requireValidationConnection(attempt)
            let imageNote = try await fetch(noteID: receipt.objectID)
            guard imageVersion != receipt.version, imageNote.summary.version == imageVersion,
                  imageNote.summary.title == title, imageNote.summary.notebookID == notebookID,
                  !imageNote.summary.isTrashed, imageNote.attachments.count == 1,
                  let image = imageNote.attachments.first, image.name == imageName,
                  image.reference.flatMap(UUID.init(uuidString:)) == imageID,
                  let dom = try? SwiftSoup.parseBodyFragment(imageNote.html),
                  try dom.select("img[ref]").array().contains(where: { try $0.attr("ref") == imageID.uuidString }) else {
                throw NoteStationError.invalidResponse
            }
            let downloadedImage = try await download(fileID: image.id, noteID: receipt.objectID)
            guard downloadedImage == png else { throw NoteStationError.invalidResponse }
            report.imageBytesVerified = true
            let markdown = "# 첨부 왕복 검증\r\n\r\n![검증 이미지](attachment://\(imageID.uuidString))\r\n"
            let source = SourceEnvelope(documentID: documentID, markdown: markdown, blocks: [], html: imageNote.html)
            let sourceBytes = source.encoded()
            let sourceName = "synology-note-source-\(documentID.uuidString).md"
            report.stage = .sourceUpload
            try requireValidationConnection(attempt)
            let finalVersion = try await uploadValidationAttachment(receipt: receipt, baseVersion: imageVersion,
                html: imageNote.html, filename: sourceName, mimeType: "text/markdown; charset=utf-8", bytes: sourceBytes, reference: nil)
            report.finalVersion = finalVersion
            report.stage = .finalRead
            try requireValidationConnection(attempt)
            let final = try await fetch(noteID: receipt.objectID)
            guard finalVersion != imageVersion, final.summary.version == finalVersion,
                  final.summary.title == title, final.summary.notebookID == notebookID,
                  !final.summary.isTrashed, final.attachments.count == 2,
                  final.attachments.contains(where: { $0.id == image.id && $0.reference == image.reference && $0.name == image.name }),
                  let sourceFile = final.attachments.first(where: { $0.name == sourceName }),
                  source.matches(html: final.html) else { throw NoteStationError.invalidResponse }
            let downloadedSource = try await download(fileID: sourceFile.id, noteID: receipt.objectID)
            guard downloadedSource == sourceBytes else { throw NoteStationError.invalidResponse }
            let decoded = try SourceEnvelope.decode(downloadedSource)
            guard decoded.documentID == documentID, decoded.matches(html: final.html),
                  Data(decoded.markdown.utf8) == Data(markdown.utf8) else { throw NoteStationError.invalidResponse }
            report.sourceBytesVerified = true
            let finalImageBytes = try await download(fileID: image.id, noteID: receipt.objectID)
            guard finalImageBytes == png else { report.imageBytesVerified = false; throw NoteStationError.invalidResponse }
            // Simulate fresh local IDs, as on another Mac. No current workspace
            // assets or user files are touched by this reconstruction check.
            let imported = final.attachments.map {
                NoteAttachment(name: $0.name, filename: UUID().uuidString, sha256: "", byteCount: 0,
                               remoteID: $0.id, remoteReference: $0.reference)
            }
            let restored = try decoded.restoredAttachments(from: imported)
            guard restored.first(where: { $0.remoteID == image.id })?.id == imageID else { throw NoteStationError.invalidResponse }
            report.markdownRestored = true
            report.stage = .completed
        } catch { report.failure = error.localizedDescription }
        return report
    }

    private func uploadValidationAttachment(receipt: WriteValidationReceipt, baseVersion: String, html: String,
        filename: String, mimeType: String, bytes: Data, reference: String?) async throws -> String {
        guard let sid else { throw NoteStationError.notConnected }
        let part = "upload-\(UUID().uuidString.lowercased())"
        var attachment: [String: Any] = ["action": "create", "format": "raw", "name": part, "rotate": false, "convert": false]
        if let reference { attachment["ref"] = reference }
        let info = try supported(Self.noteAPI, cap: 3, minimum: 2)
        var request = try makeRequest(api: Self.noteAPI, method: "set", version: info.version, info: info.info, params: [
            "object_id": receipt.objectID, "ver": baseVersion, "check_conflict": true, "content": html,
            "title": receipt.title, "brief": "SynologyNote 첨부·Markdown 검증", "attachment": [attachment],
            "mtime": Int(Date().timeIntervalSince1970), "commit_msg": ["device": "desktop", "listable": false] as [String: Any]
        ], sid: sid)
        request = try NoteStationMultipart.request(from: request, files: [
            .init(partName: part, filename: filename, mimeType: mimeType, data: bytes)
        ])
        let (responseBytes, _) = try await send(request, generation: generation)
        let response = try responseData(responseBytes)
        guard let rows = response["data"] as? [[String: Any]], rows.count == 1,
              rows[0]["object_id"] == nil || rows[0]["object_id"] as? String == receipt.objectID else {
            throw NoteStationError.invalidResponse
        }
        return try string(rows[0], "ver")
    }

    private func requireValidationConnection(_ attempt: UUID) throws {
        guard generation == attempt, sid != nil else { throw NoteStationError.connectionChanged }
    }

    private func setValidationNote(receipt: WriteValidationReceipt, baseVersion: String, html: String) async throws -> String {
        let response = try await request(api: Self.noteAPI, method: "set", cap: 3, minimum: 2, params: [
            "object_id": receipt.objectID, "ver": baseVersion, "check_conflict": true,
            "title": receipt.title, "content": html, "brief": "SynologyNote 수정·충돌 검증",
            "mtime": Int(Date().timeIntervalSince1970),
            "commit_msg": ["device": "desktop", "listable": false] as [String: Any]
        ])
        // Official setNote reads response.data[0].ver before re-fetching the note.
        guard let rows = response["data"] as? [[String: Any]], rows.count == 1,
              rows[0]["object_id"] == nil || rows[0]["object_id"] as? String == receipt.objectID else {
            throw NoteStationError.invalidResponse
        }
        return try string(rows[0], "ver")
    }

    /// Hard gate: no production write is constructed or sent until actual NAS interoperability is verified.
    public func update(noteID: String, baseVersion: String, title: String, html: String) async throws -> RemoteNote {
        _ = try await applyWrite(NoteStationWrite(objectID: noteID, baseVersion: baseVersion, title: title, html: html))
        return try await fetch(noteID: noteID)
    }

    func applyWrite(_ mutation: NoteStationWrite, uploads: [NoteStationUpload] = [], deleting: [String] = []) async throws -> NoteStationWriteReceipt {
        guard capabilities.supportsWrites else { throw NoteStationError.writeContractUnvalidated }
        var params: [String: Any] = ["mtime": Int(Date().timeIntervalSince1970),
                                   "commit_msg": ["device": "desktop", "listable": false] as [String: Any]]
        let method: String
        if let id = mutation.objectID {
            try requireIdentifier(id, name: "object_id")
            guard let version = mutation.baseVersion else { throw NoteStationError.invalidArgument("ver") }
            try requireIdentifier(version, name: "ver")
            params["object_id"] = id; params["ver"] = version; params["check_conflict"] = true
            method = "set"
        } else {
            guard let parent = mutation.notebookID, let title = mutation.title, let html = mutation.html else { throw NoteStationError.invalidArgument("create") }
            try requireIdentifier(parent, name: "parent_id")
            params["parent_id"] = parent; params["title"] = title; params["content"] = html
            params["encrypt"] = false; params["ctime"] = Int(Date().timeIntervalSince1970)
            params["latitude"] = 0; params["longitude"] = 0
            method = "create"
        }
        if let value = mutation.title { params["title"] = value }
        if let value = mutation.html { params["content"] = value; params["brief"] = String(value.prefix(180)) }
        if let value = mutation.notebookID { params["parent_id"] = value }
        if let value = mutation.tags { params["tag"] = value }
        if let value = mutation.recycle { params["recycle"] = value }
        var metadata: [[String: Any]] = deleting.map { ["action": "delete", "file_id": $0] }
        var files: [NoteStationMultipart.File] = []
        for upload in uploads {
            let part = "upload-\(UUID().uuidString)"
            var entry: [String: Any] = ["action": "create", "format": "raw", "name": part, "rotate": false, "convert": false]
            if let ref = upload.reference { entry["ref"] = ref }
            metadata.append(entry)
            files.append(.init(partName: part, filename: upload.name, mimeType: upload.mimeType, data: upload.bytes))
        }
        if !metadata.isEmpty { params["attachment"] = metadata }
        let response: [String: Any]
        if files.isEmpty {
            response = try await request(api: Self.noteAPI, method: method, cap: 3, minimum: 2, params: params)
        } else {
            guard let sid else { throw NoteStationError.notConnected }
            let info = try supported(Self.noteAPI, cap: 3, minimum: 2)
            let form = try makeRequest(api: Self.noteAPI, method: method, version: info.version, info: info.info, params: params, sid: sid)
            let uploadRequest = try NoteStationMultipart.request(from: form, files: files)
            let (bytes, _) = try await send(uploadRequest, generation: generation)
            response = try responseData(bytes)
        }
        let row: [String: Any]
        if method == "create" { row = response }
        else {
            guard let rows = response["data"] as? [[String: Any]], rows.count == 1 else { throw NoteStationError.invalidResponse }
            row = rows[0]
        }
        let id = (row["object_id"] as? String) ?? mutation.objectID
        guard let id, !id.isEmpty, mutation.objectID == nil || id == mutation.objectID else { throw NoteStationError.invalidResponse }
        summaries.removeValue(forKey: id)
        return NoteStationWriteReceipt(objectID: id, version: try string(row, "ver"))
    }

    func setFavorite(noteID: String, favorite: Bool) async throws {
        guard capabilities.supportsWrites else { throw NoteStationError.writeContractUnvalidated }
        _ = try await request(api: "SYNO.NoteStation.Shortcut", method: favorite ? "set" : "delete", cap: 1, minimum: 1, params: ["object_id": noteID], allowsEmptyData: true)
        summaries.removeValue(forKey: noteID)
    }
    func favoriteStatus(noteID: String) async throws -> Bool { try await favoriteIDs().contains(noteID) }

    func attachmentDownloadURL(fileID: String, noteID: String) throws -> String {
        let info = try supported(Self.noteAPI, cap: 1, minimum: 1)
        let request = try makeRequest(api: Self.noteAPI, method: "download", version: info.version, info: info.info,
                                     params: ["file_id": fileID, "object_id": noteID, "format": "raw", "mode": "download"], sid: nil)
        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        url.percentEncodedQuery = String(decoding: request.httpBody!, as: UTF8.self)
        return url.string!
    }

    private struct APIInfo: Decodable {
        let path: String
        let minVersion: Int
        let maxVersion: Int
        let requestFormat: String?
    }

    private func query(_ query: String, sid: String?, generation: UUID) async throws -> [String: APIInfo] {
        let info = APIInfo(path: "query.cgi", minVersion: 1, maxVersion: 1, requestFormat: nil)
        let req = try makeRequest(api: "SYNO.API.Info", method: "query", version: 1, info: info, params: ["query": query], sid: sid, raw: true)
        let (bytes, _) = try await send(req, generation: generation)
        let data = try responseData(bytes)
        do { return try JSONDecoder().decode([String: APIInfo].self, from: JSONSerialization.data(withJSONObject: data)) }
        catch { throw NoteStationError.invalidResponse }
    }

    private func supported(_ api: String, cap: Int, minimum: Int) throws -> (info: APIInfo, version: Int) {
        guard let info = apiInfo[api] else { throw NoteStationError.unsupportedAPI(api) }
        let version = min(info.maxVersion, cap)
        guard version >= max(info.minVersion, minimum) else { throw NoteStationError.unsupportedAPI(api) }
        return (info, version)
    }

    private func request(api: String, method: String, cap: Int, minimum: Int, params: [String: Any] = [:], allowsEmptyData: Bool = false) async throws -> [String: Any] {
        guard let sid else { throw NoteStationError.notConnected }
        let info = try supported(api, cap: cap, minimum: minimum)
        let req = try makeRequest(api: api, method: method, version: info.version, info: info.info, params: params, sid: sid)
        let (bytes, _) = try await send(req, generation: generation)
        return try responseData(bytes, allowsEmptyData: allowsEmptyData)
    }

    private func list(api: String, cap: Int, minimum: Int, key: String, identity: String, params: [String: Any] = [:]) async throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        var seen = Set<String>()
        var expectedTotal: Int?
        while true {
            var params = params
            params["offset"] = result.count
            params["limit"] = 500
            let data = try await request(api: api, method: "list", cap: cap, minimum: minimum, params: params)
            guard let total = data["total"] as? Int, total >= 0,
                  let offset = data["offset"] as? Int, offset == result.count,
                  expectedTotal == nil || expectedTotal == total else { throw NoteStationError.invalidResponse }
            expectedTotal = total
            let rows: [[String: Any]]
            if total == 0 && (data[key] == nil || data[key] is NSNull) { rows = [] }
            else if let value = data[key] as? [[String: Any]] { rows = value }
            else { throw NoteStationError.invalidResponse }
            guard rows.count <= total - result.count else { throw NoteStationError.invalidResponse }
            for row in rows {
                guard seen.insert(try string(row, identity)).inserted else { throw NoteStationError.invalidResponse }
            }
            result.append(contentsOf: rows)
            if result.count == total { return result }
            guard !rows.isEmpty else { throw NoteStationError.invalidResponse }
        }
    }

    private func favoriteIDs() async throws -> Set<String> {
        let shortcuts = try await list(api: "SYNO.NoteStation.Shortcut", cap: 1, minimum: 1, key: "shortcuts", identity: "id")
        return Set(try shortcuts.filter { $0["category"] as? String == "note" }.map { try string($0, "id") })
    }

    private func summary(_ row: [String: Any], fallback: RemoteNoteSummary?, favorite: Bool) throws -> RemoteNoteSummary {
        let tags: [String]
        if row["tag"] == nil || row["tag"] is NSNull { tags = fallback?.tags ?? [] }
        else if let value = row["tag"] as? [String] { tags = value }
        else { throw NoteStationError.invalidResponse }
        let notebook: String
        if row["parent_id"] == nil || row["parent_id"] is NSNull { notebook = fallback?.notebookID ?? "" }
        else { notebook = try string(row, "parent_id", allowEmpty: true) }
        let createdAt: Date?
        if row["ctime"] == nil || row["ctime"] is NSNull { createdAt = fallback?.createdAt }
        else { createdAt = try date(row, "ctime") }
        return RemoteNoteSummary(id: try string(row, "object_id"), title: try string(row, "title", allowEmpty: true),
                                 notebookID: notebook, version: try string(row, "ver"), modifiedAt: try date(row, "mtime"),
                                 createdAt: createdAt,
                                 tags: tags, isFavorite: favorite,
                                 isTrashed: try flag(row, "recycle") ?? fallback?.isTrashed ?? false,
                                 isLocked: try flag(row, "encrypt") ?? fallback?.isLocked ?? false)
    }

    private func validateBaseURL() throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw NoteStationError.invalidBaseURL }
        guard components.scheme?.lowercased() == "https" else { throw NoteStationError.insecureTransport }
    }

    private func makeRequest(api: String, method: String, version: Int, info: APIInfo, params: [String: Any], sid: String?, raw: Bool = false) throws -> URLRequest {
        try validateBaseURL()
        // An advertised path must stay under the user's configured webapi directory and origin.
        guard !info.path.isEmpty, info.path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".." && part.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
        }) else { throw NoteStationError.invalidResponse }
        let url = baseURL.appendingPathComponent("webapi").appendingPathComponent(info.path)
        var fields = ["api": api, "method": method, "version": String(version)]
        if let sid { fields["_sid"] = sid }
        let json = !raw && (info.requestFormat?.uppercased() == "JSON" || info.path == "entry.cgi")
        for (key, value) in params {
            if json || !(value is String) {
                guard JSONSerialization.isValidJSONObject([value]),
                      let text = String(data: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]), encoding: .utf8) else {
                    throw NoteStationError.invalidArgument(key)
                }
                fields[key] = text
            } else { fields[key] = value as? String }
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.keys.sorted().map { "\(encodedURL($0))=\(encodedURL(fields[$0]!))" }.joined(separator: "&").utf8)
        return request
    }

    private func encodedURL(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
    }

    private func send(_ request: URLRequest, generation attempt: UUID) async throws -> (Data, HTTPURLResponse) {
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.data(for: request, delegate: NoRedirects())
            guard generation == attempt else { throw NoteStationError.connectionChanged }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw NoteStationError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw NoteStationError.http(status: response.statusCode) }
            return (bytes, response)
        } catch let error as NoteStationError { throw error }
        catch is CancellationError { throw NoteStationError.cancelled }
        catch let error as URLError {
            if generation != attempt { throw NoteStationError.connectionChanged }
            throw error.code == .cancelled ? NoteStationError.cancelled : NoteStationError.transport(code: error.code.rawValue)
        } catch { throw NoteStationError.transport(code: URLError.unknown.rawValue) }
    }

    private func responseData(_ bytes: Data, authentication: Bool = false, allowsEmptyData: Bool = false) throws -> [String: Any] {
        guard let envelope = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let success = envelope["success"] as? Bool else { throw NoteStationError.invalidResponse }
        if !success {
            guard let error = envelope["error"] as? [String: Any], let code = error["code"] as? Int else { throw NoteStationError.invalidResponse }
            throw apiError(code, authentication: authentication)
        }
        if allowsEmptyData && (envelope["data"] == nil || envelope["data"] is NSNull) { return [:] }
        guard let data = envelope["data"] as? [String: Any] else { throw NoteStationError.invalidResponse }
        if let results = data["result"] as? [[String: Any]] {
            for result in results where result["success"] as? Bool == false {
                guard let error = result["error"] as? [String: Any], let code = error["code"] as? Int else { throw NoteStationError.invalidResponse }
                throw apiError(code, authentication: authentication)
            }
        }
        guard data["has_fail"] as? Bool != true else { throw NoteStationError.invalidResponse }
        return data
    }

    private func apiError(_ code: Int, authentication: Bool) -> NoteStationError {
        if authentication {
            if code == 403 { return .otpRequired }
            if code == 404 { return .invalidOTP }
            return .authenticationFailed(code: code)
        }
        switch code {
        case 106, 107, 119:
            disconnect()
            return .sessionExpired
        case 105: return .permissionDenied
        case 1064: return .versionConflict
        default: return .api(code: code)
        }
    }

    private func requireIdentifier(_ value: String, name: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NoteStationError.invalidArgument(name) }
    }

    private func string(_ row: [String: Any], _ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = row[key] as? String, allowEmpty || !value.isEmpty else { throw NoteStationError.invalidResponse }
        return value
    }

    private func date(_ row: [String: Any], _ key: String) throws -> Date {
        guard let value = row[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw NoteStationError.invalidResponse
        }
        return Date(timeIntervalSince1970: value.doubleValue)
    }

    private func flag(_ row: [String: Any], _ key: String) throws -> Bool? {
        guard let value = row[key], !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, number == 0 || number == 1 else { throw NoteStationError.invalidResponse }
        return number.boolValue
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension NoteStationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return coreText("The NAS address is invalid.")
        case .insecureTransport: return coreText("Use an HTTPS address to protect your credentials.")
        case .invalidArgument(let name): return coreText("Required input is missing: %@", "\(name)")
        case .notConnected: return coreText("Sign in to the NAS first.")
        case .connectionChanged: return coreText("The connection changed. The earlier request was canceled.")
        case .unsupportedAPI(let api): return coreText("The server does not support a version of this API: %@", "\(api)")
        case .authenticationFailed(let code): return coreText("NAS authentication failed (%@).", "\(code)")
        case .otpRequired: return coreText("A one-time verification code is required.")
        case .invalidOTP: return coreText("The one-time verification code is invalid.")
        case .sessionExpired: return coreText("The NAS session expired. Sign in again.")
        case .permissionDenied: return coreText("You don’t have permission to access this note.")
        case .lockedNote: return coreText("Reading encrypted notes is not supported yet.")
        case .http(let status): return coreText("The NAS HTTP request failed (%@).", "\(status)")
        case .transport(let code): return coreText("The NAS network request failed (%@).", "\(code)")
        case .cancelled: return coreText("The NAS request was canceled.")
        case .api(let code): return coreText("The Note Station API request failed (%@).", "\(code)")
        case .invalidResponse: return coreText("The Note Station response did not match the expected format.")
        case .writeContractUnvalidated: return coreText("NAS writes require a successful round-trip check on a real NAS. Local saves and NAS reads are available.")
        case .versionConflict: return coreText("The note changed on the NAS first. The server rejected the older version (1064).")
        case .notebookWriteUncertain(let id): return id == nil ? coreText("The notebook creation result is uncertain. The app will wait for you to check the NAS before creating it again.") : coreText("The NAS accepted the notebook creation request, but the list could not be verified. Checking again only refreshes the list.")
        case .stackWriteUncertain: return coreText("Could not verify the stack change. Refresh the NAS list and check the stack before trying again.")
        case .validationInProgress: return coreText("A note update and conflict check is already running.")
        }
    }
}
