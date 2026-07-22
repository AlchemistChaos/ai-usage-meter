import Foundation

/// Reads the authenticated rate-limit snapshot exposed by the installed Codex
/// app-server. The transport is added separately from the pure protocol parser
/// so protocol changes remain cheap to test.
enum CodexRateLimitClient {
    static let rateLimitRequestID = 2

    enum ClientError: LocalizedError {
        case invalidResponse
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Codex returned an incomplete rate-limit response."
            case .protocolError(let message):
                return "Codex rate-limit request failed: \(message)"
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
