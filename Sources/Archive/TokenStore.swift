import Foundation

/// What survives a relaunch: where the archive is, who we are there, and the
/// refresh token that stands in for the password. The password itself is
/// never stored; the API is explicit that the token is what to keep.
public struct ArchiveCredentials: Codable, Equatable, Sendable {
    public var baseURL: String
    public var login: String
    public var device: String
    public var refreshToken: String
    public var session: Int?

    public init(baseURL: String, login: String, device: String, refreshToken: String, session: Int?) {
        self.baseURL = baseURL
        self.login = login
        self.device = device
        self.refreshToken = refreshToken
        self.session = session
    }
}

/// A file with owner-only permissions under Application Support.
///
/// Not the keychain, deliberately: the app is ad-hoc signed, and each rebuild
/// carries a different signature, so keychain items created by one build
/// prompt or refuse under the next. A 0600 file in the user's own Library is
/// as private as the rest of their home directory and never prompts.
public struct TokenStore: Sendable {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("archive-credentials.json")
    }

    /// `~/Library/Application Support/Film Tether/`
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Film Tether", isDirectory: true)
    }

    public func load() -> ArchiveCredentials? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ArchiveCredentials.self, from: data)
    }

    public func save(_ credentials: ArchiveCredentials) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(credentials)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
