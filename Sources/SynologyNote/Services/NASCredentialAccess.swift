import Foundation
import NoteCore

struct NASCredentialAccess: Sendable {
    var load: @Sendable (String) async throws -> SavedNASCredentials?
    var save: @Sendable (SavedNASCredentials, String, Bool) async throws -> Void
    var loadInteractive: (@Sendable (String) async throws -> SavedNASCredentials?)? = nil

    static let keychain = NASCredentialAccess(
        load: { account in
            if CredentialHelperClient.isBundledApp { return try await CredentialHelperClient.load(account) }
            return try await CredentialStore.loadCredentialsAsync(account: account)
        },
        save: { credentials, account, interactive in
            if CredentialHelperClient.isBundledApp {
                try await CredentialHelperClient.save(credentials, account: account, interactive: interactive)
                return
            }
            try await Task.detached {
                if credentials.password == nil && credentials.deviceID == nil {
                    try CredentialStore.remove(account: account, allowInteraction: interactive)
                } else {
                    try CredentialStore.saveCredentials(credentials, account: account, allowInteraction: interactive)
                }
            }.value
        },
        loadInteractive: { account in
            if CredentialHelperClient.isBundledApp { return try await CredentialHelperClient.load(account, interactive: true) }
            return try await Task.detached { try CredentialStore.loadCredentials(account: account, allowInteraction: true) }.value
        }
    )
}
