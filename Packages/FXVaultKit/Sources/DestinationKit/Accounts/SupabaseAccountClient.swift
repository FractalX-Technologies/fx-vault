import Foundation
import VaultCore

/// A Supabase project the token can reach (Add Destination picker, v0.8.0).
public struct SupabaseProjectModel: Sendable, Hashable, Identifiable {
    /// The project reference (`ref`, or the older `id`).
    public let ref: String
    public let name: String
    public let region: String?
    public let organizationID: String?
    /// For example `ACTIVE_HEALTHY` or `INACTIVE`.
    public let status: String?

    public init(ref: String, name: String, region: String?, organizationID: String?, status: String?) {
        self.ref = ref
        self.name = name
        self.region = region
        self.organizationID = organizationID
        self.status = status
    }

    public var id: String {
        ref
    }
}

/// Account-level Supabase calls: checking a token and filling the project picker (v0.8.0).
public struct SupabaseAccountClient: Sendable {
    private static let refField = "ref"
    private static let idField = "id"
    private static let nameField = "name"
    private static let regionField = "region"
    private static let organizationField = "organization_id"
    private static let statusField = "status"

    private let transport: any HTTPTransporting
    private let clock: any VaultClock

    public init(transport: any HTTPTransporting, clock: any VaultClock) {
        self.transport = transport
        self.clock = clock
    }

    /// `GET /v1/projects`: every project of every organization the token can reach. Throws
    /// ``DestinationError/tokenMissing`` for an unusable token and
    /// ``DestinationError/unauthorized`` for one Supabase rejects.
    public func projects(token: SecretBytes) async throws(DestinationError) -> [SupabaseProjectModel] {
        let client = ProviderHTTPClient(provider: .supabase, transport: transport, clock: clock, credential: try .personalToken(token))
        let url = try ProviderURL.make(
            host: DestinationConstants.supabaseHost,
            segments: [SupabaseRemote.apiVersionSegment, SupabaseRemote.projectsSegment]
        )
        let response = try await client.send(.get, url, retry: .idempotent)
        defer { response.body.wipe() }
        guard let entries = try SecretJSONDocument(parsing: response.body).elements() else { throw .decoding }
        var projects: [SupabaseProjectModel] = []
        for entry in entries {
            guard let ref = entry.string(.key(Self.refField)) ?? entry.string(.key(Self.idField)) else { throw .decoding }
            projects.append(SupabaseProjectModel(
                ref: ref,
                name: entry.string(.key(Self.nameField)) ?? ref,
                region: entry.string(.key(Self.regionField)),
                organizationID: entry.string(.key(Self.organizationField)),
                status: entry.string(.key(Self.statusField))
            ))
        }
        return projects
    }
}
