// Version info - increment build number on every change
enum AppVersion {
    static let version = "0.2.0"
    static let build = 117

    static var displayString: String {
        "v\(version) (\(build))"
    }
}
