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
enum ClaudeProviderProfileHarness {
    static func main() {
        let sole = ClaudeProvider.soleStoredAccountUUID(from: [
            .init(name: "a", accountUuid: "acct-a", email: "a@example.com", plan: "max")
        ])
        expect(sole == "acct-a", "sole stored profile account id should be returned")

        let many = ClaudeProvider.soleStoredAccountUUID(from: [
            .init(name: "a", accountUuid: "acct-a", email: "a@example.com", plan: "max"),
            .init(name: "b", accountUuid: "acct-b", email: "b@example.com", plan: "max")
        ])
        expect(many == nil, "multiple stored profiles should not produce a fallback id")

        let missing = ClaudeProvider.soleStoredAccountUUID(from: [
            .init(name: "a", accountUuid: nil, email: "a@example.com", plan: "max")
        ])
        expect(missing == nil, "missing account ids should not produce a fallback id")

        print("PASS: claude provider sole stored profile")
    }
}
