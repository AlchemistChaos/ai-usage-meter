import Foundation

enum CodexLogin {
    struct Session: Equatable {
        let id: UUID
        let home: URL

        var authFile: URL { home.appending(path: "auth.json") }
        var configFile: URL { home.appending(path: "config.toml") }
    }

    enum LoginError: LocalizedError {
        case executableNotFound

        var errorDescription: String? {
            switch self {
            case .executableNotFound:
                return "Codex CLI not found. Install or update Codex, then try again."
            }
        }
    }

    static func prepare(in root: URL) throws -> Session {
        let loginRoot = root.appending(path: "codex-login")
        let session = Session(
            id: UUID(),
            home: loginRoot.appending(path: UUID().uuidString))
        try FileManager.default.createDirectory(
            at: session.home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let config = "cli_auth_credentials_store = \"file\"\n"
        try Data(config.utf8).write(to: session.configFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: session.configFile.path())
        return session
    }

    static func cleanup(_ session: Session) {
        try? FileManager.default.removeItem(at: session.home)
    }

    static func copyCredential(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path())
    }

    static func makeProcess(
        for session: Session
    ) throws -> (process: Process, errorPipe: Pipe) {
        guard let executable = executableURL() else {
            throw LoginError.executableNotFound
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["login"]
        process.currentDirectoryURL = session.home

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = session.home.path()
        environment["CODEX_SQLITE_HOME"] = session.home.path()
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        return (process, errorPipe)
    }

    static func executableURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = environment["CCM_CODEX_EXECUTABLE"] {
            candidates.append(override)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path()
        candidates.append(contentsOf: [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ])
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                "\($0)/codex"
            })
        }

        return candidates.lazy
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path()) }
    }
}
