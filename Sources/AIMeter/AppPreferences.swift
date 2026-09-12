import Foundation

enum AppPreferences {
    static let suiteName = "com.alchemistchaos.aimeter"
    static let store = UserDefaults(suiteName: suiteName) ?? .standard
}
