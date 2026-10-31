import Foundation
import Security

/// The user's development certificate (.p12), which DuoCode signs extensions' macOS programs
/// with so iOS will run them (see NativeTools.mm). iOS only loads code signed by the team that
/// signed the app, so it has to be the certificate DuoCode was installed with: in Plume
/// Impactor, Settings > Export P12. Kept in the Keychain, on this device only.
enum SigningCertificate {
    static let didChange = Notification.Name("DuoCodeSigningCertificateDidChange")

    private static let service = "com.duocode.signing-certificate"
    private static let teamKey = "signingCertificate.team"

    /// The imported certificate's team ID, or nil if there isn't one.
    static var team: String? { UserDefaults.standard.string(forKey: teamKey) }

    static var isImported: Bool { team != nil }

    /// The team that signed DuoCode, from its provisioning profile.
    static let appTeam: String? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return (plist["TeamIdentifier"] as? [String])?.first
    }()

    /// Checks and stores a .p12. Returns its team ID, or throws why it can't be used.
    @discardableResult
    static func importCertificate(_ data: Data, password: String) throws -> String {
        let team = try teamID(of: data, password: password)
        if let appTeam, appTeam != team {
            throw error("This certificate is from team \(team), but Mobile Studio was installed by team \(appTeam). Export the certificate of the Apple ID you install Mobile Studio with.")
        }
        let blob = try JSONSerialization.data(withJSONObject: ["p12": data.base64EncodedString(), "password": password])
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = blob
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw error("The certificate couldn't be saved (error \(status)).") }
        UserDefaults.standard.set(team, forKey: teamKey)
        data.withUnsafeBytes { dc_native_tools_set_certificate($0.baseAddress, $0.count, password) }
        NotificationCenter.default.post(name: didChange, object: nil)
        return team
    }

    static func remove() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: teamKey)
        dc_native_tools_set_certificate(nil, 0, nil)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Gives the stored certificate to the program runner (at launch).
    static func load() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let blob = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: blob) as? [String: String],
              let p12 = json["p12"].flatMap({ Data(base64Encoded: $0) }) else { return }
        p12.withUnsafeBytes { dc_native_tools_set_certificate($0.baseAddress, $0.count, json["password"] ?? "") }
    }

    private static func teamID(of data: Data, password: String) throws -> String {
        var out = [CChar](repeating: 0, count: 512)
        let status = data.withUnsafeBytes { dc_native_tools_certificate_team($0.baseAddress, $0.count, password, &out, out.count) }
        let text = String(cString: out)
        guard status == 0 else { throw error(text) }
        return text
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "SigningCertificate", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
