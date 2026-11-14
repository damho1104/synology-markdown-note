import Foundation
import Security
import CryptoKit
import NoteCore

enum CredentialHelperClient {
    private struct Request: Encodable {
        let action: String
        let account: String
        let credentials: SavedNASCredentials?
        let interactive: Bool
    }
    private struct Reply: Decodable {
        let credentials: SavedNASCredentials?
        let status: Int32
    }

    static var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func load(_ account: String, interactive: Bool = false) async throws -> SavedNASCredentials? {
        try await execute(Request(action: "load", account: account, credentials: nil, interactive: interactive)).credentials
    }

    static func save(_ credentials: SavedNASCredentials, account: String, interactive: Bool) async throws {
        let action = credentials.password == nil && credentials.deviceID == nil ? "remove" : "save"
        _ = try await execute(Request(action: action, account: account, credentials: credentials, interactive: interactive))
    }

    private static func execute(_ request: Request) async throws -> Reply {
        try await Task.detached(priority: .userInitiated) {
            let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SynologyCredentialHelper")
            try verifyHelper(executable)
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = executable
            process.standardInput = input; process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + (request.interactive ? 180 : 3))
            timer.setEventHandler { if process.isRunning { process.terminate() } }
            timer.resume()
            defer { timer.cancel() }
            try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request))
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CredentialStoreError.keychain(status: errSecInteractionNotAllowed) }
            guard data.count < 65536, let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw CredentialStoreError.invalidData }
            guard reply.status == errSecSuccess else { throw CredentialStoreError.keychain(status: reply.status) }
            return reply
        }.value
    }

    private static func verifyHelper(_ url: URL) throws {
        var own: SecCode?, information: CFDictionary?
        var staticOwn: SecStaticCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &staticOwn) == errSecSuccess, let staticOwn,
              SecCodeCopySigningInformation(staticOwn, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate], let certificate = certificates.first else {
            throw CredentialStoreError.keychain(status: errSecAuthFailed)
        }
        let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        let rule = "identifier \"com.damho.SynologyMarkdown.CredentialHelper\" and certificate leaf = H\"\(fingerprint)\""
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw CredentialStoreError.keychain(status: errSecAuthFailed)
        }
    }
}
