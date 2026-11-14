import Foundation
import CryptoKit

struct ConnectionProfile: Codable, Equatable, Sendable {
    var server = ""
    var username = ""
    var rememberPassword = true
    var autoConnect = true
    var rememberDevice = true
    var keepOffline = true

    init(server: String = "", username: String = "", rememberPassword: Bool = true,
         autoConnect: Bool = true, rememberDevice: Bool = true, keepOffline: Bool = true) {
        self.server = server; self.username = username; self.rememberPassword = rememberPassword
        self.autoConnect = autoConnect; self.rememberDevice = rememberDevice
        self.keepOffline = keepOffline
    }
    // Legacy autoUpload values are ignored: NAS edits always sync automatically.
    private enum CodingKeys: String, CodingKey { case server, username, rememberPassword, autoConnect, rememberDevice, keepOffline }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        server = try values.decode(String.self, forKey: .server)
        username = try values.decode(String.self, forKey: .username)
        rememberPassword = try values.decodeIfPresent(Bool.self, forKey: .rememberPassword) ?? true
        autoConnect = try values.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        rememberDevice = try values.decodeIfPresent(Bool.self, forKey: .rememberDevice) ?? true
        keepOffline = try values.decodeIfPresent(Bool.self, forKey: .keepOffline) ?? true
    }
    var storageKey: String {
        guard !server.isEmpty, !username.isEmpty else { return "local" }
        let identity = server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "\n" + username
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func load(from preferences: UserDefaults = .standard) -> Self {
        guard let data = preferences.data(forKey: "connectionProfile"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func persist(to preferences: UserDefaults = .standard) { preferences.set(try? JSONEncoder().encode(self), forKey: "connectionProfile") }
}
