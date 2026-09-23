import Foundation
import os

/// Unified-log events. Only metadata is recorded (bundle IDs, lengths, counts,
/// timings, error cases); dictated text and macro output never are.
final class Diagnostics: Sendable {
    private let logger = Logger(
        subsystem: "com.jarod.doubao-voice-helper",
        category: "runtime"
    )

    func event(
        _ name: String,
        bundleIdentifier: String? = nil,
        button: Int64? = nil,
        detail: String? = nil
    ) {
        let bundle = bundleIdentifier ?? "unknown"
        let buttonValue = button.map(String.init) ?? "none"
        let detailValue = detail ?? "none"
        logger.notice(
            "event=\(name, privacy: .public) bundle=\(bundle, privacy: .public) button=\(buttonValue, privacy: .public) detail=\(detailValue, privacy: .public)"
        )
    }
}
