import Foundation
import VaultCore

/// One Vercel project environment's variables through the REST API (v0.8.0,
/// `https://api.vercel.com`, a personal access token; every request carries `teamId` when the
/// project belongs to a team).
///
/// - `list()`: `GET /v10/projects/<id>/env` (values are not decrypted). The answer is
///   `{"envs": […], "pagination"?}`, `{"envs": […], "hiddenProductionEnvCount"}`, an array, or
///   a single variable; `pagination.next` is followed with `until`. Only variables whose
///   `target` (a string or an array) includes this environment are returned. When production
///   variables are hidden from the token and this is production, the list throws
///   ``DestinationError/forbidden`` instead of returning an incomplete list.
/// - `readValue`: `GET /v1/projects/<id>/env/<env id>`, `value` read with the scanner.
/// - `setValue`: a new name is `POST /v10/projects/<id>/env?upsert=true` with
///   `{"key", "value", "type", "target": [<environment>]}` and its `failed` array is checked; an
///   existing one is `PATCH /v9/projects/<id>/env/<env id>` with `{"value", "type"}`, which
///   changes it for its ``RemoteDestinationItemModel/otherTargets`` too (VaultData shows that).
///   Types: variable → `plain`; secret → `encrypted`, or `sensitive` when it already is.
/// - `delete`: `DELETE /v9/projects/<id>/env/<env id>`, or, when the variable has other
///   targets, `PATCH` of its `target` to those (only this environment is removed).
struct VercelRemote: DestinationRemoting {
    let provider = DestinationProvider.vercel

    private enum VariableType {
        static let plain = "plain"
        static let encrypted = "encrypted"
        static let sensitive = "sensitive"
        static let secret = "secret"
        static let system = "system"
    }

    private enum Visibility {
        static let config = "config"
        static let secret = "secret"
    }

    private enum Field {
        static let envs = "envs"
        static let key = "key"
        static let id = "id"
        static let value = "value"
        static let type = "type"
        static let target = "target"
        static let gitBranch = "gitBranch"
        static let customEnvironmentIDs = "customEnvironmentIds"
        static let system = "system"
        static let visibility = "visibility"
        static let updatedAt = "updatedAt"
        static let decrypted = "decrypted"
        static let hiddenProductionEnvCount = "hiddenProductionEnvCount"
        static let created = "created"
        static let failed = "failed"
        static let error = "error"
        static let code = "code"
    }

    private static let listVersion = "v10"
    private static let readVersion = "v1"
    private static let editVersion = "v9"
    private static let createVersion = "v10"
    private static let projectsSegment = "projects"
    private static let envSegment = "env"
    private static let upsertKey = "upsert"
    private static let upsertValue = "true"

    private let projectID: String
    private let teamID: String?
    private let environment: VercelEnvironment
    private let client: ProviderHTTPClient

    init(projectID: String, teamID: String?, environment: VercelEnvironment, client: ProviderHTTPClient) {
        self.projectID = projectID
        self.teamID = teamID
        self.environment = environment
        self.client = client
    }

    // MARK: - DestinationRemoting

    func list() async throws(DestinationError) -> [RemoteDestinationItemModel] {
        var items: [RemoteDestinationItemModel] = []
        var seenIDs: Set<String> = []
        var until: Int64?
        for _ in 0..<DestinationConstants.maxListPages {
            let pageQuery = until.map { [(name: VercelPagination.untilKey, value: String($0))] } ?? []
            let url = try VercelURL.make(segments: [Self.listVersion, Self.projectsSegment, projectID, Self.envSegment], teamID: teamID, query: pageQuery)
            let response = try await client.send(.get, url, retry: .idempotent)
            defer { response.body.wipe() }
            let document = try SecretJSONDocument(parsing: response.body)
            if environment == .production, (document.integer(.key(Field.hiddenProductionEnvCount)) ?? 0) > 0 {
                throw .forbidden
            }
            var addedNew = false
            for entry in try Self.variables(in: document) {
                if let id = entry.string(.key(Field.id)) {
                    guard seenIDs.insert(id).inserted else { continue }
                }
                addedNew = true
                if let item = try Self.item(from: entry, environment: environment) {
                    items.append(item)
                }
            }
            guard addedNew, let next = VercelPagination.nextTimestamp(in: document), next != until else {
                return items
            }
            until = next
        }
        throw .responseTooLarge
    }

    func readValue(of item: RemoteDestinationItemModel) async throws(DestinationError) -> SecretBytes {
        try RemoteWriteCheck.requireReadable(item)
        let url = try VercelURL.make(segments: [Self.readVersion, Self.projectsSegment, projectID, Self.envSegment, try remoteRef(of: item)], teamID: teamID)
        let response = try await client.send(.get, url, retry: .idempotent)
        defer { response.body.wipe() }
        let document = try SecretJSONDocument(parsing: response.body)
        let type = document.string(.key(Field.type))
        guard type != VariableType.sensitive, type != VariableType.system else {
            throw .invalidRequest(code: DestinationError.LocalCode.writeOnly)
        }
        let isEncrypted = type == VariableType.encrypted || type == VariableType.secret
        if isEncrypted, document.bool(.key(Field.decrypted)) == false {
            throw .decoding
        }
        guard let value = document.secret(.key(Field.value)) else {
            throw .invalidRequest(code: DestinationError.LocalCode.writeOnly)
        }
        return value
    }

    func setValue(
        _ value: SecretBytes,
        name: String,
        kind: ConfigKind,
        existing: RemoteDestinationItemModel?
    ) async throws(DestinationError) -> RemoteWriteResultModel {
        let storedKind = try RemoteWriteCheck.validate(name: name, kind: kind, value: value, provider: provider)
        let type: String
        if storedKind == .variable {
            type = VariableType.plain
        } else if let existing, existing.kind == .secret, !existing.isValueReadable {
            type = VariableType.sensitive
        } else {
            type = VariableType.encrypted
        }

        if let existing, existing.remoteRef != nil {
            let url = try editURL(try remoteRef(of: existing))
            let body = JSONBodyValue.members([Field.value: .secret(value), Field.type: .string(type)])
            let response = try await client.send(.patch, url, body: body, retry: .never)
            defer { response.body.wipe() }
            return Self.writeResult(from: try SecretJSONDocument(parsing: response.body))
        }

        let url = try VercelURL.make(
            segments: [Self.createVersion, Self.projectsSegment, projectID, Self.envSegment],
            teamID: teamID,
            query: [(name: Self.upsertKey, value: Self.upsertValue)]
        )
        let body = JSONBodyValue.members([
            Field.key: .string(name),
            Field.value: .secret(value),
            Field.type: .string(type),
            Field.target: .strings([environment.rawValue]),
        ])
        let response = try await client.send(.post, url, body: body, retry: .never)
        defer { response.body.wipe() }
        let document = try SecretJSONDocument(parsing: response.body)
        if let failures = document.elements(.key(Field.failed)), let first = failures.first {
            let code = DestinationError.sanitizedCode(first.string(.key(Field.error), .key(Field.code)))
            let codes = code.map { [$0] } ?? []
            throw ProviderErrorMapper.isAlreadyExists(codes) ? .conflict(code: code) : .invalidRequest(code: code)
        }
        let created = document.child(.key(Field.created), .index(0)) ?? document.child(.key(Field.created))
        guard let created else { throw .decoding }
        return Self.writeResult(from: created)
    }

    func delete(_ item: RemoteDestinationItemModel) async throws(DestinationError) {
        let url = try editURL(try remoteRef(of: item))
        if item.otherTargets.isEmpty {
            let response = try await client.send(.delete, url, retry: .idempotent)
            response.body.wipe()
        } else {
            let body = JSONBodyValue.members([Field.target: .strings(item.otherTargets.map(\.rawValue))])
            let response = try await client.send(.patch, url, body: body, retry: .never)
            response.body.wipe()
        }
    }

    // MARK: - Decoding

    /// The variables of one list answer, whichever of Vercel's shapes it has.
    static func variables(in document: SecretJSONDocument) throws(DestinationError) -> [SecretJSONDocument] {
        if let elements = document.elements() {
            return elements
        }
        if let envs = document.elements(.key(Field.envs)) {
            return envs
        }
        if document.contains(.key(Field.key)) {
            return [document]
        }
        throw .decoding
    }

    /// The listed variable as an item of `environment`, or nil when it does not apply to it.
    static func item(from entry: SecretJSONDocument, environment: VercelEnvironment) throws(DestinationError) -> RemoteDestinationItemModel? {
        guard let key = entry.string(.key(Field.key)), !key.isEmpty else { throw .decoding }
        let targets = entry.strings(.key(Field.target)) ?? entry.string(.key(Field.target)).map { [$0] } ?? []
        let standardTargets = Set(targets.compactMap(VercelEnvironment.init(rawValue:)))
        guard standardTargets.contains(environment) else { return nil }

        let type = entry.string(.key(Field.type)) ?? ""
        let isSystem = type == VariableType.system || entry.bool(.key(Field.system)) == true
        let gitBranch = entry.string(.key(Field.gitBranch)) ?? ""
        let customEnvironments = entry.strings(.key(Field.customEnvironmentIDs)) ?? []
        let reason: DestinationUnusableReason?
        if isSystem {
            reason = .system
        } else if !gitBranch.isEmpty {
            reason = .gitBranch
        } else if !customEnvironments.isEmpty {
            reason = .customEnvironment
        } else {
            reason = DestinationRules.unusableReason(forRemoteName: key, provider: .vercel).map(DestinationUnusableReason.invalidName)
        }

        let kind: ConfigKind
        switch entry.string(.key(Field.visibility)) {
        case Visibility.config: kind = .variable
        case Visibility.secret: kind = .secret
        default: kind = type == VariableType.plain ? .variable : .secret
        }
        let updated = entry.integer(.key(Field.updatedAt))
        return RemoteDestinationItemModel(
            remoteName: key,
            name: DestinationRules.localName(forRemoteName: key, provider: .vercel),
            unusableReason: reason,
            kind: kind,
            remoteRef: entry.string(.key(Field.id)),
            version: updated.map(String.init),
            isValueReadable: type != VariableType.sensitive && !isSystem,
            otherTargets: VercelEnvironment.allCases.filter { $0 != environment && standardTargets.contains($0) },
            updatedAt: updated.map(ProviderDate.milliseconds)
        )
    }

    private static func writeResult(from variable: SecretJSONDocument) -> RemoteWriteResultModel {
        RemoteWriteResultModel(
            version: variable.integer(.key(Field.updatedAt)).map(String.init),
            remoteRef: variable.string(.key(Field.id))
        )
    }

    // MARK: - URLs

    private func editURL(_ remoteRef: String) throws(DestinationError) -> URL {
        try VercelURL.make(segments: [Self.editVersion, Self.projectsSegment, projectID, Self.envSegment, remoteRef], teamID: teamID)
    }

    private func remoteRef(of item: RemoteDestinationItemModel) throws(DestinationError) -> String {
        guard let remoteRef = item.remoteRef, DestinationRules.isValidVercelIdentifier(remoteRef),
              PathSegmentValidator.isValid(remoteRef)
        else {
            throw .invalidRequest(code: DestinationError.LocalCode.missingRemoteRef)
        }
        return remoteRef
    }
}

/// Vercel URLs: `https://api.vercel.com/<segments>?<query>[&teamId=<team>]`.
enum VercelURL {
    static let teamIDKey = "teamId"

    static func make(
        segments: [String],
        teamID: String?,
        query: [(name: String, value: String)] = []
    ) throws(DestinationError) -> URL {
        var items = query
        if let teamID {
            items.append((name: teamIDKey, value: teamID))
        }
        return try ProviderURL.make(host: DestinationConstants.vercelHost, segments: segments, query: items)
    }
}

/// Vercel's list pagination: `{"pagination": {"count", "next", "prev"}}`. `next` is a timestamp
/// (passed back as `until`) or, for projects, a continuation token (passed back as `from`).
enum VercelPagination {
    static let untilKey = "until"
    static let fromKey = "from"
    private static let paginationField = "pagination"
    private static let nextField = "next"

    /// `pagination.next` when it is a number.
    static func nextTimestamp(in document: SecretJSONDocument) -> Int64? {
        document.integer(.key(paginationField), .key(nextField))
    }

    /// The query item for the next page, or nil when there is none.
    static func nextQuery(in document: SecretJSONDocument) -> (name: String, value: String)? {
        if let timestamp = nextTimestamp(in: document) {
            return (untilKey, String(timestamp))
        }
        if let token = document.string(.key(paginationField), .key(nextField)), !token.isEmpty {
            return (fromKey, token)
        }
        return nil
    }
}
