import Foundation
import Darwin

/// Reads the authenticated rate-limit snapshot exposed by the installed Codex
/// app-server. The transport is added separately from the pure protocol parser
/// so protocol changes remain cheap to test.
enum CodexRateLimitClient {
    static let rateLimitRequestID = 2
    static let appServerArguments = ["app-server", "--listen", "stdio://"]

    enum ClientError: LocalizedError {
        case invalidResponse
        case protocolError(String)
        case timedOut
        case serverClosed(String?)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Codex returned an incomplete rate-limit response."
            case .protocolError(let message):
                return "Codex rate-limit request failed: \(message)"
            case .timedOut:
                return "Codex rate-limit request timed out."
            case .serverClosed(let detail):
                return detail.map { "Codex app server stopped: \($0)" }
                    ?? "Codex app server stopped before returning limits."
            case .transport(let message):
                return "Codex app-server transport failed: \(message)"
            }
        }
    }

    private struct Response: Decodable {
        let id: Int?
        let result: ResultPayload?
        let error: ErrorPayload?
    }

    private struct ResultPayload: Decodable {
        let rateLimits: RateLimits?
    }

    private struct RateLimits: Decodable {
        let primary: Window?
        let secondary: Window?
        let planType: String?
    }

    private struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: Int64?
    }

    private struct ErrorPayload: Decodable {
        let message: String
    }

    static func requestPayload() -> Data {
        let initialize = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-meter","version":"0.1"}}}"#
        let limits = #"{"id":2,"method":"account/rateLimits/read","params":null}"#
        return Data("\(initialize)\n\(limits)\n".utf8)
    }

    static func decodeSnapshot(
        from data: Data,
        capturedAt: Date
    ) throws -> CodexProvider.Snapshot? {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.id == rateLimitRequestID else { return nil }
        if let error = response.error {
            throw ClientError.protocolError(error.message)
        }
        guard let limits = response.result?.rateLimits else {
            throw ClientError.invalidResponse
        }

        let windows: [UsageWindow] = [limits.primary, limits.secondary].compactMap { window in
            guard let window,
                  let minutes = window.windowDurationMins,
                  minutes > 0
            else { return nil }
            return UsageWindow(
                label: label(for: minutes),
                usedPercent: window.usedPercent,
                windowMinutes: minutes,
                resetsAt: window.resetsAt.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                })
        }
        guard !windows.isEmpty else { throw ClientError.invalidResponse }
        return CodexProvider.Snapshot(
            windows: windows,
            plan: limits.planType,
            capturedAt: capturedAt)
    }

    static func decodeSnapshot(
        fromStream data: Data,
        capturedAt: Date
    ) throws -> CodexProvider.Snapshot? {
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let snapshot = try decodeSnapshot(
                from: Data(line), capturedAt: capturedAt) {
                return snapshot
            }
        }
        return nil
    }

    static func fetchSnapshot(
        timeout: TimeInterval = 10
    ) async throws -> CodexProvider.Snapshot {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(
                        returning: try fetchSnapshotBlocking(timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func fetchSnapshotBlocking(
        timeout: TimeInterval
    ) throws -> CodexProvider.Snapshot {
        guard let executable = CodexLogin.executableURL() else {
            throw CodexLogin.LoginError.executableNotFound
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = appServerArguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let errorLock = NSLock()
        var errorData = Data()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            errorLock.lock()
            if errorData.count < 4_096 {
                errorData.append(chunk.prefix(4_096 - errorData.count))
            }
            errorLock.unlock()
        }

        defer {
            errors.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        try process.run()
        try input.fileHandleForWriting.write(contentsOf: requestPayload())

        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        let outputHandle = output.fileHandleForReading
        var buffer = Data()

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ClientError.timedOut }
            let millis = Int32(min(remaining * 1_000, Double(Int32.max)))
            var descriptor = pollfd(
                fd: outputHandle.fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0)
            let result = Darwin.poll(&descriptor, 1, millis)
            if result == 0 { throw ClientError.timedOut }
            if result < 0 {
                if errno == EINTR { continue }
                throw ClientError.transport(String(cString: strerror(errno)))
            }

            let chunk = outputHandle.availableData
            guard !chunk.isEmpty else {
                errorLock.lock()
                let detail = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                errorLock.unlock()
                throw ClientError.serverClosed(
                    detail.flatMap { $0.isEmpty ? nil : String($0.prefix(500)) })
            }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if let snapshot = try decodeSnapshot(
                    from: line, capturedAt: Date()) {
                    return snapshot
                }
            }
        }
    }

    private static func label(for minutes: Int) -> String {
        switch minutes {
        case 300: return "5h"
        case 10_080: return "Weekly"
        case 1_440: return "Daily"
        default:
            if minutes % 10_080 == 0 { return "\(minutes / 10_080)w" }
            if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
            if minutes % 60 == 0 { return "\(minutes / 60)h" }
            return "\(minutes)m"
        }
    }
}
