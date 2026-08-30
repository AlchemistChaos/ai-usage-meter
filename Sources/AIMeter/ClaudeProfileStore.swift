import Foundation

enum ClaudeAuthOrigin: String, Equatable {
    case appOAuth
    case legacy
}

enum ClaudeProfileStore {
    struct Identity: Equatable {
        let accountUUID: String
        let email: String?
        let plan: String?
    }

    struct Record {
        let identity: Identity
        let origin: ClaudeAuthOrigin
        let credentialURL: URL
        let expiresAt: Date?
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ccmanager")
    }

    static func profilesDirectory(root: URL = defaultRoot) -> URL {
        root.appending(path: "profiles/claude")
    }

    static func credentialURL(
        accountUUID: String,
        root: URL = defaultRoot
    ) -> URL {
        profilesDirectory(root: root)
            .appending(path: accountUUID)
            .appending(path: "credentials.json")
    }

    static func list(root: URL = defaultRoot) -> [Record] {
        let directory = profilesDirectory(root: root)
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path())) ?? []
        return names.compactMap { name in
            decodeRecord(at: directory.appending(path: name)
                .appending(path: "credentials.json"))
        }.sorted {
            ($0.identity.email ?? $0.identity.accountUUID)
                .localizedCaseInsensitiveCompare(
                    $1.identity.email ?? $1.identity.accountUUID) == .orderedAscending
        }
    }

    static func record(
        accountUUID: String,
        root: URL = defaultRoot
    ) -> Record? {
        decodeRecord(at: credentialURL(accountUUID: accountUUID, root: root))
    }

    @discardableResult
    static func saveCredential(
        _ data: Data,
        identity: Identity,
        origin: ClaudeAuthOrigin,
        root: URL = defaultRoot
    ) throws -> URL {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        object["_ccmanagerIdentity"] = [
            "accountUuid": identity.accountUUID,
            "email": identity.email ?? "",
            "plan": identity.plan ?? "",
        ]
        object["_ccmanagerAuth"] = [
            "origin": origin.rawValue,
            "schemaVersion": 1,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: object)
        let destination = credentialURL(accountUUID: identity.accountUUID, root: root)
        try atomicWrite(encoded, to: destination)
        return destination
    }

    static func migrateLegacyProfiles(root: URL = defaultRoot) throws {
        let directory = profilesDirectory(root: root)
        try secureDirectory(directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path())
        for name in names where !name.hasPrefix(".") {
            let source = directory.appending(path: name).appending(path: "credentials.json")
            guard let sourceRecord = decodeRecord(at: source) else { continue }
            if name == sourceRecord.identity.accountUUID,
               sourceRecord.origin == .appOAuth || sourceRecord.origin == .legacy {
                continue
            }

            try backup(source, legacyName: name, root: root)
            let destination = credentialURL(
                accountUUID: sourceRecord.identity.accountUUID, root: root)
            if let existing = decodeRecord(at: destination),
               (existing.expiresAt ?? .distantPast) >= (sourceRecord.expiresAt ?? .distantPast) {
                try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
                continue
            }
            let data = try Data(contentsOf: source)
            try saveCredential(
                data,
                identity: sourceRecord.identity,
                origin: sourceRecord.origin == .appOAuth ? .appOAuth : .legacy,
                root: root)
            if source.standardizedFileURL != destination.standardizedFileURL {
                try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            }
        }
    }

    private static func decodeRecord(at url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identityObject = object["_ccmanagerIdentity"] as? [String: Any],
              let accountUUID = identityObject["accountUuid"] as? String,
              !accountUUID.isEmpty
        else { return nil }
        let auth = object["_ccmanagerAuth"] as? [String: Any]
        let origin = (auth?["origin"] as? String).flatMap(ClaudeAuthOrigin.init(rawValue:))
            ?? .legacy
        let oauth = object["claudeAiOauth"] as? [String: Any]
        let expiresAt = (oauth?["expiresAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1_000)
        }
        func nonempty(_ value: Any?) -> String? {
            (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return Record(
            identity: .init(
                accountUUID: accountUUID,
                email: nonempty(identityObject["email"]),
                plan: nonempty(identityObject["plan"])),
            origin: origin,
            credentialURL: url,
            expiresAt: expiresAt)
    }

    private static func atomicWrite(_ data: Data, to destination: URL) throws {
        try secureDirectory(destination.deletingLastPathComponent())
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".credentials-\(UUID().uuidString).json")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: temporary.path())
        if FileManager.default.fileExists(atPath: destination.path()) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination.path())
    }

    private static func secureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path())
    }

    private static func backup(_ source: URL, legacyName: String, root: URL) throws {
        let directory = root.appending(path: "backups/claude")
        try secureDirectory(directory)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let destination = directory.appending(path: "\(legacyName)-\(stamp).json")
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination.path())
    }
}
