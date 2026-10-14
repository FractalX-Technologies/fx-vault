import Foundation

/// Rejects strings that are unsafe as one URL path segment or one file-name component (D29).
///
/// Runs at every boundary: UI entry, GitHub import, share import, database load and the gh
/// command layer (owner, repository, environment and item names; clone folder names).
/// GitHubKit's `GitHubPath` additionally percent-encodes and re-checks.
///
/// Rejected: empty strings; `.` and `..`; `/` and `\`; control, bidi and zero-width characters
/// (``UnicodeScalarPolicy``); and any percent-encoded form (up to
/// ``Limits/maxPercentDecodingPasses`` levels deep) that decodes to a dot segment, a separator
/// or a control character.
public enum PathSegmentValidator {
    private static let dotSegments: Set<String> = [".", ".."]
    private static let separators: Set<Character> = ["/", "\\"]

    /// Returns `segment` unchanged when it is safe.
    @discardableResult
    public static func validate(_ segment: String) throws(ValidationError) -> String {
        if let rule = violation(in: segment) {
            throw .invalidPathSegment(rule)
        }
        return segment
    }

    /// True when ``validate(_:)`` would accept `segment`.
    public static func isValid(_ segment: String) -> Bool {
        violation(in: segment) == nil
    }

    /// The first rule `segment` breaks, or nil.
    public static func violation(in segment: String) -> PathSegmentRule? {
        if segment.isEmpty { return .empty }
        if let rule = literalViolation(in: segment) { return rule }

        var current = segment
        for _ in 0..<Limits.maxPercentDecodingPasses {
            guard let decoded = current.removingPercentEncoding, decoded != current else {
                return nil
            }
            if dotSegments.contains(decoded) { return .encodedDotSegment }
            if let rule = literalViolation(in: decoded) {
                return rule == .dotSegment ? .encodedDotSegment : rule
            }
            current = decoded
        }
        return nil
    }

    /// Checks the string as written (no decoding).
    private static func literalViolation(in segment: String) -> PathSegmentRule? {
        if let violation = UnicodeScalarPolicy.firstViolation(in: segment) {
            switch violation {
            case .control: return .controlCharacter
            case .bidi: return .bidiCharacter
            case .zeroWidth: return .zeroWidthCharacter
            }
        }
        if dotSegments.contains(segment) { return .dotSegment }
        if segment.contains(where: { separators.contains($0) }) { return .separator }
        return nil
    }
}
