import Foundation
import Security
import CryptoKit

// This executable changes only when credential handling changes, not when the
// editor/UI changes. Keychain's cdhash partition can therefore remain stable.
@main struct CredentialHelper {
    struct Request: Decodable {
        let action: String
        let account: String
        let credentials: SavedNASCredentials?
        let interactive: Bool
    }
    struct Reply: Encodable {
        var credentials: SavedNASCredentials?
        var status: Int32 = 0
    }

    static func main() {
        guard trustedParent() else { exit(77) }
        var reply = Reply()
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard data.count < 65536 else { exit(64) }
            let request = try JSONDecoder().decode(Request.self, from: data)
            switch request.action {
            case "load": reply.credentials = try CredentialStore.loadCredentials(account: request.account, allowInteraction: request.interactive)
            case "save":
                guard let credentials = request.credentials else { exit(64) }
                try CredentialStore.saveCredentials(credentials, account: request.account, allowInteraction: request.interactive)
            case "remove": try CredentialStore.remove(account: request.account, allowInteraction: request.interactive)
            default: exit(64)
            }
        } catch CredentialStoreError.keychain(let status) { reply.status = status }
        catch { reply.status = errSecDecode }
        guard let data = try? JSONEncoder().encode(reply) else { exit(70) }
        FileHandle.standardOutput.write(data)
    }

    private static func trustedParent() -> Bool {
        var own: SecCode?, information: CFDictionary?
        var staticOwn: SecStaticCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &staticOwn) == errSecSuccess, let staticOwn,
              SecCodeCopySigningInformation(staticOwn, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else { return false }
        let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        let rule = "identifier \"com.damho.SynologyMarkdown\" and certificate leaf = H\"\(fingerprint)\""
        var requirement: SecRequirement?, parent: SecCode?
        let pid = getppid()
        guard pid > 1,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &parent) == errSecSuccess,
              let parent, let requirement else { return false }
        return SecCodeCheckValidity(parent, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess && getppid() == pid
    }
}
