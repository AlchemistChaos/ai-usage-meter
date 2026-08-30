import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func credential(
    uuid: String,
    email: String,
    expiresAt: Double
) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "claudeAiOauth": [
            "accessToken": "access-\(uuid)",
            "refreshToken": "refresh-\(uuid)",
            "expiresAt": expiresAt,
        ],
        "_ccmanagerIdentity": [
            "accountUuid": uuid,
            "email": email,
            "plan": "max",
        ],
    ])
}

@main
enum ClaudeProfileStoreHarness {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ai-meter-profile-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try ClaudeProfileStore.saveCredential(
            credential(uuid: "account-a", email: "river@ultima.inc", expiresAt: 100),
            identity: .init(
                accountUUID: "account-a", email: "river@ultima.inc", plan: "max"),
            origin: .appOAuth,
            root: root)
        let second = try ClaudeProfileStore.saveCredential(
            credential(uuid: "account-b", email: "river@gmail.com", expiresAt: 200),
            identity: .init(
                accountUUID: "account-b", email: "river@gmail.com", plan: "max"),
            origin: .appOAuth,
            root: root)

        expect(first != second, "UUIDs must define distinct profile paths")
        expect(
            ClaudeProfileStore.list(root: root).compactMap(\.identity.email).sorted()
                == ["river@gmail.com", "river@ultima.inc"],
            "same-prefix emails must remain visible together")

        _ = try ClaudeProfileStore.saveCredential(
            credential(uuid: "account-a", email: "river@ultima.inc", expiresAt: 300),
            identity: .init(
                accountUUID: "account-a", email: "river@ultima.inc", plan: "max"),
            origin: .appOAuth,
            root: root)
        expect(ClaudeProfileStore.list(root: root).count == 2,
               "re-adding one UUID must update instead of duplicate")
        let permissions = try FileManager.default.attributesOfItem(
            atPath: first.path())[.posixPermissions] as? NSNumber
        expect(permissions?.intValue == 0o600,
               "saved Claude credentials must be owner-readable only")

        let legacy = root.appending(path: "profiles/claude/legacy-name/credentials.json")
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try credential(
            uuid: "legacy-account", email: "legacy@example.com", expiresAt: 400)
            .write(to: legacy)

        try ClaudeProfileStore.migrateLegacyProfiles(root: root)
        try ClaudeProfileStore.migrateLegacyProfiles(root: root)
        let migrated = ClaudeProfileStore.record(
            accountUUID: "legacy-account", root: root)
        expect(migrated?.origin == .legacy,
               "migrated credentials must be marked legacy")
        expect(ClaudeProfileStore.list(root: root).count == 3,
               "migration must be idempotent")
        let backups = root.appending(path: "backups/claude")
        expect(((try? FileManager.default.contentsOfDirectory(
            atPath: backups.path())) ?? []).count == 1,
            "legacy migration must create exactly one backup")

        print("PASS: UUID-keyed Claude profile storage")
    }
}
