import Foundation
import GeraldineControl

/// The Application Support folder for state Geraldine creates on its own: the
/// control socket and chart history. Production bundles leave
/// `GeraldineSupportFolderName` unset and keep `Application Support/Geraldine`.
/// An update-test lane names its own folder so it never shares live state with
/// the installed app.
enum SupportDirectory {
    static let infoKey = "GeraldineSupportFolderName"

    static let folderName = folderName(in: Bundle.main.infoDictionary ?? [:])

    static func folderName(in info: [String: Any]) -> String {
        guard let raw = info[infoKey] as? String else { return ControlEndpoint.defaultSupportFolderName }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else {
            return ControlEndpoint.defaultSupportFolderName
        }
        return name
    }
}
