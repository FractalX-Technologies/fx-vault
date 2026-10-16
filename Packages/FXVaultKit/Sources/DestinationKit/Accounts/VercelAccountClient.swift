import Foundation
import VaultCore

/// The Vercel user a token belongs to (v0.8.0). No email is kept.
public struct VercelUserModel: Sendable, Hashable {
    public let id: String
    public let username: String
    /// The team Vercel opens by default, if any.
    public let defaultTeamID: String?

    public init(id: String, username: String, defaultTeamID: String?) {
        self.id = id
        self.username = username
        self.defaultTeamID = defaultTeamID
    }
}

/// A Vercel team the token can reach.
public struct VercelTeamModel: Sendable, Hashable, Identifiable {
    public let id: String
    public let slug: String
    public let name: String?

    public init(id: String, slug: String, name: String?) {
        self.id = id
        self.slug = slug
        self.name = name
    }
}

/// A Vercel project (the Add Destination picker).
public struct VercelProjectModel: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Account-level Vercel calls: checking a token and filling the team and project pickers
/// (v0.8.0). Answers are read with the secret JSON scanner because project objects embed
/// environment variables.
public struct VercelAccountClient: Sendable {
    private enum Field {
        static let user = "user"
        static let id = "id"
        static let username = "username"
        static let defaultTeamID = "defaultTeamId"
        static let teams = "teams"
        static let slug = "slug"
        static let name = "name"
        static let projects = "projects"
    }

    private static let userPath = ["v2", "user"]
    private static let teamsPath = ["v2", "teams"]
    private static let projectsPath = ["v10", "projects"]
    private static let limitKey = "limit"

    private let transport: any HTTPTransporting
    private let clock: any VaultClock

    public init(transport: any HTTPTransporting, clock: any VaultClock) {
        self.transport = transport
        self.clock = clock
    }

    /// `GET /v2/user`.
    public func user(token: SecretBytes) async throws(DestinationError) -> VercelUserModel {
        let client = try self.client(token)
        let response = try await client.send(.get, try VercelURL.make(segments: Self.userPath, teamID: nil), retry: .idempotent)
        defer { response.body.wipe() }
        let document = try SecretJSONDocument(parsing: response.body)
        guard let user = document.child(.key(Field.user)),
              let id = user.string(.key(Field.id)),
              let username = user.string(.key(Field.username))
        else { throw .decoding }
        return VercelUserModel(id: id, username: username, defaultTeamID: user.string(.key(Field.defaultTeamID)))
    }

    /// `GET /v2/teams?limit=100`, following `pagination.next` with `until`.
    public func teams(token: SecretBytes) async throws(DestinationError) -> [VercelTeamModel] {
        let client = try self.client(token)
        return try await paginate(client: client, path: Self.teamsPath, teamID: nil, listField: Field.teams) { entry throws(DestinationError) in
            guard let id = entry.string(.key(Field.id)), let slug = entry.string(.key(Field.slug)) else { throw .decoding }
            return VercelTeamModel(id: id, slug: slug, name: entry.string(.key(Field.name)))
        }
    }

    /// `GET /v10/projects?limit=100[&teamId=…]`, following `pagination.next` with `until` (a
    /// timestamp) or `from` (a continuation token). The answer may also be a bare array.
    public func projects(token: SecretBytes, teamID: String?) async throws(DestinationError) -> [VercelProjectModel] {
        if let teamID, !DestinationRules.isValidVercelIdentifier(teamID) {
            throw .invalidInput(.invalidDestinationTarget(.vercelTeam))
        }
        let client = try self.client(token)
        return try await paginate(client: client, path: Self.projectsPath, teamID: teamID, listField: Field.projects) { entry throws(DestinationError) in
            guard let id = entry.string(.key(Field.id)), let name = entry.string(.key(Field.name)) else { throw .decoding }
            return VercelProjectModel(id: id, name: name)
        }
    }

    private func client(_ token: SecretBytes) throws(DestinationError) -> ProviderHTTPClient {
        ProviderHTTPClient(provider: .vercel, transport: transport, clock: clock, credential: try .personalToken(token))
    }

    /// Reads every page of a list whose items are under `listField` (or a bare array).
    private func paginate<Element: Identifiable>(
        client: ProviderHTTPClient,
        path: [String],
        teamID: String?,
        listField: String,
        decode: (SecretJSONDocument) throws(DestinationError) -> Element
    ) async throws(DestinationError) -> [Element] where Element.ID == String {
        var result: [Element] = []
        var seen: Set<String> = []
        var pageQuery: (name: String, value: String)?
        for _ in 0..<DestinationConstants.maxListPages {
            var query = [(name: Self.limitKey, value: String(DestinationConstants.vercelPageSize))]
            if let pageQuery {
                query.append(pageQuery)
            }
            let response = try await client.send(.get, try VercelURL.make(segments: path, teamID: teamID, query: query), retry: .idempotent)
            defer { response.body.wipe() }
            let document = try SecretJSONDocument(parsing: response.body)
            guard let entries = document.elements(.key(listField)) ?? document.elements() else { throw .decoding }
            var addedNew = false
            for entry in entries {
                let element = try decode(entry)
                if seen.insert(element.id).inserted {
                    result.append(element)
                    addedNew = true
                }
            }
            guard addedNew, let next = VercelPagination.nextQuery(in: document), next.value != pageQuery?.value else {
                return result
            }
            pageQuery = next
        }
        throw .responseTooLarge
    }
}
