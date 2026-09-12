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
enum MenuAgentLauncherHarness {
    static func main() {
        let app = URL(fileURLWithPath: "/Applications/AI Meter.app")
        let raw = URL(fileURLWithPath: "/tmp/AIMeter")
        let normalArguments = ["AIMeter"]

        expect(
            MenuAgentLauncher.shouldRelay(
                bundleURL: app,
                arguments: normalArguments),
            "a bundled launch should relay to the menu agent")
        expect(
            !MenuAgentLauncher.shouldRelay(
                bundleURL: raw,
                arguments: normalArguments),
            "a raw helper must not relay recursively")
        expect(
            !MenuAgentLauncher.shouldRelay(
                bundleURL: app,
                arguments: ["AIMeter", MenuAgentLauncher.markerArgument]),
            "the explicit menu-agent marker must prevent recursive relays")

        let support = URL(fileURLWithPath: "/Users/test/Library/Application Support")
        expect(
            MenuAgentLauncher.helperURL(applicationSupportURL: support).path
                == "/Users/test/Library/Application Support/AI Meter/Menu Agent/AIMeter",
            "the helper should use a stable Application Support path")
        expect(
            MenuAgentLauncher.bundledHelperURL(bundleURL: app).path
                == "/Applications/AI Meter.app/Contents/Helpers/AIMeterMenuAgent",
            "the launcher should copy the separately signed bundled helper")
        expect(
            MenuAgentLauncher.relayedArguments(["AIMeter", "--status-item-selftest"])
                == ["--status-item-selftest", MenuAgentLauncher.markerArgument],
            "relay arguments should preserve the command and append one marker")

        print("PASS: menu agent launcher")
    }
}
