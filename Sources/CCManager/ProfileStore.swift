import Foundation

/// Manages saved account profiles on disk and swapping which one is "active".
///
/// Layout:
///   ~/.ccmanager/profiles/codex/<name>/auth.json
///   ~/.ccmanager/backups/codex/auth-<timestamp>.json
///
/// Switching = copy a stored profile's auth.json over ~/.codex/auth.json,
/// after backing up whatever is currently there.
enum ProfileStore {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var root: URL { home.appending(path: ".ccmanager") }
    static var profilesRoot: URL { root.appending(path: "profiles") }
    static var backupsRoot: URL { root.appending(path: "backups") }

    /// The live credential file each CLI actually reads.
    static func activeCredentialPath(_ provider: ProviderKind) -> URL {
        switch provider {
        case .codex: return home.appending(path: ".codex/auth.json")
        case .claude: return home.appending(path: ".claude/.credentials.json")
        }
    }

    static func profilesDir(_ provider: ProviderKind) -> URL {
        profilesRoot.appending(path: provider.rawValue)
    }

    static func profileFile(_ provider: ProviderKind, _ name: String) -> URL {
        profilesDir(provider).appending(path: name).appending(path: "auth.json")
    }

    static func ensureDirs() throws {
        for p in ProviderKind.allCases {
            try FileManager.default.createDirectory(
                at: profilesDir(p), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: backupsRoot.appending(path: p.rawValue), withIntermediateDirectories: true)
        }
    }

    static func listProfiles(_ provider: ProviderKind) -> [String] {
        let dir = profilesDir(provider)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path())) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .filter { FileManager.default.fileExists(atPath: profileFile(provider, $0).path()) }
            .sorted()
    }

    /// Capture whatever credentials are currently live into a named profile.
    /// This is how you register an account: log in with the CLI, then import.
    @discardableResult
    static func importActive(_ provider: ProviderKind, as name: String) throws -> URL {
        try ensureDirs()
        let src = activeCredentialPath(provider)
        guard FileManager.default.fileExists(atPath: src.path()) else {
            throw CCError.notLoggedIn(provider)
        }
        return try importCredential(provider, from: src, as: name)
    }

    /// Save a credential produced in an isolated login home without changing
    /// the credential file used by the active CLI account.
    @discardableResult
    static func importCredential(
        _ provider: ProviderKind,
        from source: URL,
        as name: String
    ) throws -> URL {
        try ensureDirs()
        let dest = profileFile(provider, name)
        try CodexLogin.copyCredential(from: source, to: dest)
        return dest
    }

    /// Make a stored profile the active one, backing up the current credentials first.
    static func activate(_ provider: ProviderKind, name: String) throws {
        let src = profileFile(provider, name)
        guard FileManager.default.fileExists(atPath: src.path()) else {
            throw CCError.missingProfile(name)
        }
        let live = activeCredentialPath(provider)

        // Back up current creds so a bad switch is always recoverable.
        if FileManager.default.fileExists(atPath: live.path()) {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = backupsRoot
                .appending(path: provider.rawValue)
                .appending(path: "auth-\(stamp).json")
            try FileManager.default.createDirectory(
                at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: live, to: backup)
        }

        try FileManager.default.createDirectory(
            at: live.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Write via a temp file in the same directory, then atomically replace,
        // so a crash mid-switch can never leave truncated credentials behind.
        let data = try Data(contentsOf: src)
        let tmp = live.deletingLastPathComponent()
            .appending(path: ".auth-swap-\(UUID().uuidString).json")
        try data.write(to: tmp, options: .atomic)
        try restrictPermissions(tmp)
        _ = try FileManager.default.replaceItemAt(live, withItemAt: tmp)
        try restrictPermissions(live)
    }

    /// Credentials are secrets — keep them owner-only (0600).
    private static func restrictPermissions(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path())
    }

    /// Which stored profile matches the currently live credentials?
    /// Compared by account identity rather than bytes, since tokens refresh in place.
    static func activeProfileName(_ provider: ProviderKind) -> String? {
        guard let liveID = CodexProvider.accountIdentity(at: activeCredentialPath(provider))
        else { return nil }
        for name in listProfiles(provider) {
            if CodexProvider.accountIdentity(at: profileFile(provider, name)) == liveID {
                return name
            }
        }
        return nil
    }
}

enum CCError: LocalizedError {
    case notLoggedIn(ProviderKind)
    case missingProfile(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let p):
            return "No active \(p.displayName) credentials found to import. Log in with the CLI first."
        case .missingProfile(let n):
            return "Profile '\(n)' no longer exists on disk."
        }
    }
}
