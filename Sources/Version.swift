import Foundation

// Version info - build number is sourced from CFBundleVersion at build time
enum AppVersion {
    static let version = "0.2.0"
    private static let fallbackBuild = 164

    static var build: Int {
        Int(buildString) ?? fallbackBuild
    }

    static var buildString: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return String(fallbackBuild)
    }

    static var track: String {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        if bundleID.contains(".dev") {
            return "dev"
        }
        if bundleID.contains(".release") {
            return "rel"
        }
        return "local"
    }

    static var displayString: String {
        "v\(version) \(track).\(buildString)"
    }
}
