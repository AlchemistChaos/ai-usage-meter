import Foundation

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
enum CodexLoginHarness {
    static func main() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: "ccmanager-login-harness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true)

        let activeCredential = fixtureRoot.appending(path: "active-auth.json")
        let sentinel = Data("existing-active-account".utf8)
        try sentinel.write(to: activeCredential)

        let stagingRoot = fixtureRoot.appending(path: "app-data")
        let session = try CodexLogin.prepare(in: stagingRoot)

        expect(FileManager.default.fileExists(atPath: session.home.path()),
               "isolated CODEX_HOME should be created")
        let activeAfterPrepare = try Data(contentsOf: activeCredential)
        expect(activeAfterPrepare == sentinel,
               "preparing isolated login must not alter active credentials")

        let config = try String(contentsOf: session.configFile, encoding: .utf8)
        expect(config.contains("cli_auth_credentials_store = \"file\""),
               "isolated login must force file credential storage")
        expect(session.authFile.deletingLastPathComponent().pathComponents
                   == session.home.pathComponents,
               "isolated auth file should live inside the staging home")

        let runner = try CodexLogin.makeProcess(for: session)
        expect(runner.process.executableURL != nil,
               "installed Codex executable should be discoverable")
        expect(runner.process.environment?["CODEX_HOME"] == session.home.path(),
               "Codex process must receive only the isolated CODEX_HOME")
        expect(runner.process.environment?["CODEX_SQLITE_HOME"] == session.home.path(),
               "Codex process state must remain inside the isolated home")

        let isolatedCredential = Data("new-isolated-account".utf8)
        try isolatedCredential.write(to: session.authFile)
        let importedCredential = fixtureRoot
            .appending(path: "profiles/new-account/auth.json")
        try CodexLogin.copyCredential(
            from: session.authFile,
            to: importedCredential)
        let importedData = try Data(contentsOf: importedCredential)
        expect(importedData == isolatedCredential,
               "isolated credentials should copy into the saved profile")
        let permissions = try FileManager.default.attributesOfItem(
            atPath: importedCredential.path())[.posixPermissions] as? NSNumber
        expect(permissions?.intValue == 0o600,
               "saved credentials should be owner-readable only")

        CodexLogin.cleanup(session)
        expect(!FileManager.default.fileExists(atPath: session.home.path()),
               "isolated credentials should be removed after completion")
        let activeAfterCleanup = try Data(contentsOf: activeCredential)
        expect(activeAfterCleanup == sentinel,
               "cleanup must not alter active credentials")

        print("PASS: isolated Codex login staging")
    }
}
