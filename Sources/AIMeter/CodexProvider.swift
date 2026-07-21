import Foundation
import SQLite3

/// Reads Codex account identity and real usage limits.
///
/// Identity comes from the JWT in ~/.codex/auth.json.
/// Usage comes from the `x-codex-*` response headers that the Codex CLI already
/// logs into ~/.codex/logs_2.sqlite on every API call. Harvesting those is free
/// and accurate — it costs no quota and needs no network request.
enum CodexProvider {

    // MARK: - Identity

    struct Identity {
        let accountID: String
        let email: String?
        let plan: String?
    }

    /// Decode the id_token JWT to recover who this credential belongs to.
    static func identity(at url: URL) -> Identity? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any]
        else { return nil }

        let accountID = tokens["account_id"] as? String

        guard let idToken = tokens["id_token"] as? String,
              let claims = decodeJWTPayload(idToken)
        else {
            return accountID.map { Identity(accountID: $0, email: nil, plan: nil) }
        }

        let email = claims["email"] as? String
        var plan: String?
        var claimAccount: String?
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
            plan = auth["chatgpt_plan_type"] as? String
            claimAccount = auth["chatgpt_account_id"] as? String
        }
        guard let id = accountID ?? claimAccount else { return nil }
        return Identity(accountID: id, email: email, plan: plan)
    }

    /// Stable identity string used to tell profiles apart.
    static func accountIdentity(at url: URL) -> String? {
        identity(at: url)?.accountID
    }

    private static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-pad: base64url strips trailing '='.
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Usage

    struct Snapshot {
        let windows: [UsageWindow]
        let plan: String?
        let capturedAt: Date
    }

    static var logsDB: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/logs_2.sqlite")
    }

    /// Pull the most recent rate-limit headers Codex logged locally.
    ///
    /// Codex prunes this table and only records these headers occasionally, so
    /// the newest match can sit far from the newest row — a bounded scan misses
    /// it. Measured full-table cost is ~90ms on a 200MB / 115k-row database,
    /// which is cheap enough to just scan the lot.
    static func latestSnapshot() -> Snapshot? {
        guard FileManager.default.fileExists(atPath: logsDB.path()) else { return nil }

        var db: OpaquePointer?
        // Read-only, and tolerate the WAL that a running Codex holds open.
        guard sqlite3_open_v2(logsDB.path(), &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT feedback_log_body, ts FROM logs
            WHERE feedback_log_body LIKE '%x-codex-primary-used-percent%'
            ORDER BY id DESC LIMIT 1
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cText = sqlite3_column_text(stmt, 0)
        else { return nil }
        let body = String(cString: cText)
        let tsSeconds = Double(sqlite3_column_int64(stmt, 1))

        // Codex logs ts in whichever unit the build uses; normalise plausible epochs.
        let captured = normaliseTimestamp(tsSeconds) ?? Date()
        return parseHeaders(from: body, capturedAt: captured)
    }

    private static func normaliseTimestamp(_ raw: Double) -> Date? {
        guard raw > 0 else { return nil }
        // Try seconds, then ms, then ns — accept whatever lands in a sane range.
        for divisor in [1.0, 1_000.0, 1_000_000_000.0] {
            let d = Date(timeIntervalSince1970: raw / divisor)
            if d > Date(timeIntervalSince1970: 1_600_000_000),
               d < Date().addingTimeInterval(86_400) {
                return d
            }
        }
        return nil
    }

    /// Extract the x-codex-* limit headers out of a logged request line.
    static func parseHeaders(from body: String, capturedAt: Date) -> Snapshot? {
        func header(_ name: String) -> String? {
            // Headers are logged as: "x-codex-foo": "value"
            guard let r = body.range(of: "\"\(name)\": \"", options: .backwards) else { return nil }
            let rest = body[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            let value = String(rest[..<end])
            return value.isEmpty ? nil : value
        }

        func window(_ prefix: String, fallbackLabel: String) -> UsageWindow? {
            guard let usedStr = header("x-codex-\(prefix)-used-percent"),
                  let used = Double(usedStr) else { return nil }
            let minutes = Int(header("x-codex-\(prefix)-window-minutes") ?? "") ?? 0
            // A zero-length window means the provider isn't enforcing it.
            guard minutes > 0 else { return nil }

            var resetsAt: Date?
            if let atStr = header("x-codex-\(prefix)-reset-at"), let at = Double(atStr), at > 0 {
                resetsAt = Date(timeIntervalSince1970: at)
            } else if let afterStr = header("x-codex-\(prefix)-reset-after-seconds"),
                      let after = Double(afterStr), after > 0 {
                resetsAt = capturedAt.addingTimeInterval(after)
            }

            return UsageWindow(
                label: labelFor(minutes: minutes) ?? fallbackLabel,
                usedPercent: used,
                windowMinutes: minutes,
                resetsAt: resetsAt)
        }

        let windows = [
            window("primary", fallbackLabel: "Primary"),
            window("secondary", fallbackLabel: "Secondary"),
        ].compactMap { $0 }

        guard !windows.isEmpty else { return nil }
        return Snapshot(
            windows: windows,
            plan: header("x-codex-plan-type"),
            capturedAt: capturedAt)
    }

    /// Turn a raw window length into the label a user recognises.
    private static func labelFor(minutes: Int) -> String? {
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
