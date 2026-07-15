import Foundation

/// Shared ISO-8601 parsing for tool metadata files (Codex writes both plain
/// and fractional-seconds timestamps). One home so every store parses alike.
enum ISO8601 {
    static func date(from string: String) -> Date? {
        plain.date(from: string) ?? fractional.date(from: string)
    }

    // ISO8601DateFormatter is documented thread-safe; creating one per call is not free.
    private nonisolated(unsafe) static let plain = ISO8601DateFormatter()
    private nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
