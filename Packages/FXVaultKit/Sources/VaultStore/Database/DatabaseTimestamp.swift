import Foundation
import GRDB

/// The one timestamp format of the vault database (§6 Formats): ISO-8601 UTC TEXT with
/// millisecond precision, for example `2026-10-15T09:30:00.250Z`.
///
/// Every value has the same width, so text order equals time order and SQL range filters on
/// `started_at` (journal retention, throttle seeding) can compare strings. Sub-millisecond
/// precision is dropped on write.
public enum DatabaseTimestamp {
    private static let writeStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    /// The database text for a date.
    public static func string(from date: Date) -> String {
        writeStyle.format(date)
    }

    /// Parses database text. Accepts the canonical form and the same form without fractional
    /// seconds. Returns nil for anything else.
    public static func date(from string: String) -> Date? {
        if let date = try? writeStyle.parse(string) {
            return date
        }
        return try? wholeSecondStyle.parse(string)
    }

    /// The date as it reads back after a database round trip (truncated to milliseconds).
    public static func roundTripped(_ date: Date) -> Date? {
        self.date(from: string(from: date))
    }

    /// GRDB encoding strategy used by every record in VaultStore.
    static let encodingStrategy = DatabaseDateEncodingStrategy.custom { date in
        string(from: date)
    }

    /// GRDB decoding strategy used by every record in VaultStore.
    static let decodingStrategy = DatabaseDateDecodingStrategy.custom { dbValue in
        String.fromDatabaseValue(dbValue).flatMap(date(from:))
    }
}
