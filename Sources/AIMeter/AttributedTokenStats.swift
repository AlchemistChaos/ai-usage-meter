import Foundation

enum TokenAttribution: String, Codable {
    case observedActiveSpan
    case singleProfileFallback
    case unattributed
}

struct AttributedTokenStats: Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheWriteTokens = 0
    var cacheReadTokens = 0
    var totalTokens = 0
    var attribution: TokenAttribution = .unattributed

    var isEmpty: Bool { totalTokens == 0 }
}
