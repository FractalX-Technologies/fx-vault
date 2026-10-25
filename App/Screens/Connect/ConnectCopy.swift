import Foundation

/// Counted texts of the Connect phase (automatic grammar agreement: "1 repository").
enum ConnectCopy {
    static func personalRepositories(_ count: Int) -> String {
        inflected(AttributedString(
            localized: "connect.source.personal",
            defaultValue: "^[\(count) personal repository](inflect: true)"
        ))
    }

    static func organizations(_ count: Int) -> String {
        inflected(AttributedString(
            localized: "connect.summary.organizationCount",
            defaultValue: "^[\(count) organization](inflect: true)"
        ))
    }

    static func repositories(_ count: Int, environments: Int) -> String {
        inflected(AttributedString(
            localized: "connect.summary.repositoryCount",
            defaultValue: "^[\(count) repository](inflect: true) · ^[\(environments) environment](inflect: true)"
        ))
    }

    static func total(secrets: Int, variables: Int) -> String {
        inflected(AttributedString(
            localized: "connect.summary.total",
            defaultValue: "Total · ^[\(secrets) secret](inflect: true) · ^[\(variables) variable](inflect: true)"
        ))
    }

    private static func inflected(_ text: AttributedString) -> String {
        String(text.characters)
    }
}
