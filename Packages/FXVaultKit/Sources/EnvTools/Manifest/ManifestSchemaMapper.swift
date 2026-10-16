import VaultCore

/// Maps the reader's node tree onto ``ManifestModel``, applying every manifest rule.
///
/// Errors drop the smallest unit that cannot be represented faithfully (see
/// ``ManifestIssue/Kind``): a per-stage entry, a `to` or `stages` reference, a target or a
/// variable. A dropped target is remembered, so variables sending to it do not add an
/// "undefined target" issue on top of the target's own issue; such references are removed,
/// and a variable left with no target is dropped. Nodes the reader already reported
/// (``ManifestNode/Value/invalid``) are skipped silently.
struct ManifestSchemaMapper {
    /// The reader stopped inside an unclosed flow collection: top-level fields after it were
    /// never read, so their absence is not reported on top of the reader's issue.
    private let isTruncated: Bool
    private(set) var issues: [ManifestIssue] = []
    private var stages: [String] = []
    private var stageByFoldKey: [String: String] = [:]
    private var droppedTargetNames: Set<String> = []

    /// The outcome of checking one scalar of a target setting.
    private enum Checked<Value> {
        case valid(Value)
        case invalid(ManifestIssue.Kind)
    }

    init(isTruncated: Bool = false) {
        self.isTruncated = isTruncated
    }

    mutating func map(_ root: ManifestNode?) -> ManifestModel? {
        guard let root else {
            report(.emptyManifest, line: 1)
            return nil
        }
        guard let fields = mapping(root, field: nil, key: nil) else { return nil }
        for entry in fields where !ManifestField.topLevel.contains(entry.key) {
            report(.unknownField(entry.key), line: entry.keyLine)
        }
        let lookup = Self.lookup(fields)
        if let version = lookup[ManifestField.version], !checkVersion(version) { return nil }

        var isComplete = true
        for name in [ManifestField.stages, ManifestField.targets, ManifestField.vars] where lookup[name] == nil {
            if !isTruncated { report(.missingField(name), line: root.line) }
            isComplete = false
        }
        if let stagesEntry = lookup[ManifestField.stages], !mapStages(stagesEntry) {
            isComplete = false
        }
        guard isComplete else {
            // Still point out a wrong type in the sections that were not mapped.
            for name in [ManifestField.targets, ManifestField.vars] {
                if let entry = lookup[name] { _ = mapping(entry.value, field: name, key: nil) }
            }
            return nil
        }
        guard let targetsEntry = lookup[ManifestField.targets],
              let varsEntry = lookup[ManifestField.vars],
              let targets = mapTargets(targetsEntry),
              let vars = mapVars(varsEntry, targets: targets) else { return nil }
        return ManifestModel(version: ManifestModel.currentVersion, stages: stages, targets: targets, vars: vars)
    }

    // MARK: - Version and stages

    private mutating func checkVersion(_ entry: ManifestEntry) -> Bool {
        guard let version = integer(entry.value, field: ManifestField.version, key: nil) else { return false }
        guard version == ManifestModel.currentVersion else {
            report(.unsupportedVersion, line: entry.value.line)
            return false
        }
        return true
    }

    private mutating func mapStages(_ entry: ManifestEntry) -> Bool {
        guard let nodes = sequence(entry.value, field: ManifestField.stages, key: nil) else { return false }
        guard nodes.count <= EnvToolsLimits.maxManifestStages else {
            report(.tooManyStages(limit: EnvToolsLimits.maxManifestStages), line: entry.value.line)
            return false
        }
        guard !nodes.isEmpty else {
            report(.noStages, line: entry.value.line)
            return false
        }
        for node in nodes {
            guard let name = text(node, field: ManifestField.stages, key: nil) else { continue }
            if let error = EnvironmentNameValidator.violation(in: name) {
                report(.invalidStageName(error), line: node.line, key: name)
                continue
            }
            let normalized = EnvironmentNameValidator.normalize(name)
            let foldKey = EnvironmentNameValidator.foldKey(normalized)
            guard stageByFoldKey[foldKey] == nil else {
                report(.duplicateStage, line: node.line, key: normalized)
                continue
            }
            stageByFoldKey[foldKey] = normalized
            stages.append(normalized)
        }
        return !stages.isEmpty
    }

    /// The declared spelling of `name`, compared case-insensitively.
    private func declaredStage(_ name: String) -> String? {
        stageByFoldKey[EnvironmentNameValidator.foldKey(name)]
    }

    // MARK: - Targets

    private mutating func mapTargets(_ entry: ManifestEntry) -> [ManifestTargetModel]? {
        guard let entries = mapping(entry.value, field: ManifestField.targets, key: nil) else { return nil }
        guard entries.count <= EnvToolsLimits.maxManifestTargets else {
            report(.tooManyTargets(limit: EnvToolsLimits.maxManifestTargets), line: entry.value.line)
            return nil
        }
        var targets: [ManifestTargetModel] = []
        for target in entries {
            if let model = mapTarget(target) {
                targets.append(model)
            } else {
                droppedTargetNames.insert(target.key)
            }
        }
        return targets
    }

    private mutating func mapTarget(_ entry: ManifestEntry) -> ManifestTargetModel? {
        let name = entry.key
        guard ManifestIdentifierValidator.isValidTargetName(name) else {
            report(.invalidTargetName, line: entry.keyLine, key: name)
            return nil
        }
        guard let fields = mapping(entry.value, field: nil, key: name) else { return nil }
        let lookup = Self.lookup(fields)
        guard let providerEntry = lookup[ManifestField.provider] else {
            report(.missingField(ManifestField.provider), line: entry.keyLine, key: name)
            return nil
        }
        guard let providerName = text(providerEntry.value, field: ManifestField.provider, key: name) else {
            return nil
        }
        guard let provider = ManifestProvider(rawValue: providerName) else {
            report(.unknownProvider, line: providerEntry.value.line, key: name)
            return nil
        }
        for field in fields where !provider.fieldNames.contains(field.key) {
            report(.unknownField(field.key), line: field.keyLine, key: name)
        }
        let configuration: ManifestTargetConfiguration?
        switch provider {
        case .githubActions:
            configuration = gitHubConfiguration(lookup, target: entry)
        case .azureKeyVault:
            let vault = requiredStageValue(ManifestField.vault, in: lookup, target: entry) { value, stage -> Checked<String> in
                guard DestinationRules.isValidKeyVaultName(value) else {
                    return .invalid(.invalidVaultName(stage: stage))
                }
                return .valid(value)
            }
            configuration = vault.map { ManifestTargetConfiguration.azureKeyVault(vault: $0) }
        case .supabase:
            let project = requiredStageValue(ManifestField.project, in: lookup, target: entry) { value, stage -> Checked<String> in
                guard DestinationRules.isValidSupabaseProjectRef(value) else {
                    return .invalid(.invalidProjectRef(stage: stage))
                }
                return .valid(value)
            }
            configuration = project.map { ManifestTargetConfiguration.supabase(project: $0) }
        case .vercel:
            configuration = vercelConfiguration(lookup, target: entry)
        }
        guard let configuration else { return nil }
        return ManifestTargetModel(name: name, configuration: configuration, line: entry.keyLine)
    }

    private mutating func gitHubConfiguration(
        _ lookup: [String: ManifestEntry],
        target: ManifestEntry
    ) -> ManifestTargetConfiguration? {
        guard let entry = lookup[ManifestField.environment] else { return .githubActions(environment: nil) }
        let environment = stageValue(entry, target: target.key) { value, stage -> Checked<String> in
            if let error = EnvironmentNameValidator.violation(in: value) {
                return .invalid(.invalidGitHubEnvironment(error, stage: stage))
            }
            return .valid(EnvironmentNameValidator.normalize(value))
        }
        return environment.map { .githubActions(environment: $0) }
    }

    private mutating func vercelConfiguration(
        _ lookup: [String: ManifestEntry],
        target: ManifestEntry
    ) -> ManifestTargetConfiguration? {
        let name = target.key
        guard let projectEntry = lookup[ManifestField.project] else {
            report(.missingField(ManifestField.project), line: target.keyLine, key: name)
            return nil
        }
        guard let project = text(projectEntry.value, field: ManifestField.project, key: name) else { return nil }
        guard ManifestIdentifierValidator.isValidVercelProject(project) else {
            report(.invalidVercelProject, line: projectEntry.value.line, key: name)
            return nil
        }
        var team: String?
        if let teamEntry = lookup[ManifestField.team] {
            guard let value = text(teamEntry.value, field: ManifestField.team, key: name) else { return nil }
            guard ManifestIdentifierValidator.isValidVercelTeam(value) else {
                report(.invalidVercelTeam, line: teamEntry.value.line, key: name)
                return nil
            }
            team = value
        }
        var environment: ManifestStageValue<ManifestVercelEnvironment>?
        if let environmentEntry = lookup[ManifestField.environment] {
            environment = stageValue(environmentEntry, target: name) { value, stage -> Checked<ManifestVercelEnvironment> in
                guard let environment = ManifestVercelEnvironment(rawValue: value) else {
                    return .invalid(.invalidVercelEnvironment(stage: stage))
                }
                return .valid(environment)
            }
            guard environment != nil else { return nil }
        }
        return .vercel(project: project, team: team, environment: environment)
    }

    private mutating func requiredStageValue<Value: Sendable & Hashable>(
        _ field: String,
        in lookup: [String: ManifestEntry],
        target: ManifestEntry,
        check: (String, String?) -> Checked<Value>
    ) -> ManifestStageValue<Value>? {
        guard let entry = lookup[field] else {
            report(.missingField(field), line: target.keyLine, key: target.key)
            return nil
        }
        return stageValue(entry, target: target.key, check: check)
    }

    /// One scalar for every stage, or a `{ stage: value }` mapping over declared stages. Nil
    /// when the setting is unusable at every stage (wrong type, or an invalid single value);
    /// invalid per-stage entries are reported and left out.
    private mutating func stageValue<Value: Sendable & Hashable>(
        _ entry: ManifestEntry,
        target: String,
        check: (String, String?) -> Checked<Value>
    ) -> ManifestStageValue<Value>? {
        let node = entry.value
        switch node.value {
        case .scalar(let text, _):
            switch check(text, nil) {
            case .valid(let value):
                return .everyStage(value)
            case .invalid(let kind):
                report(kind, line: node.line, key: target)
                return nil
            }
        case .mapping(let stageEntries):
            var values: [String: Value] = [:]
            for stageEntry in stageEntries {
                guard let stage = declaredStage(stageEntry.key) else {
                    report(.undeclaredStage(stageEntry.key), line: stageEntry.keyLine, key: target)
                    continue
                }
                guard values[stage] == nil else {
                    report(.duplicateReference(stageEntry.key), line: stageEntry.keyLine, key: target)
                    continue
                }
                guard let text = text(stageEntry.value, field: entry.key, key: target) else { continue }
                switch check(text, stage) {
                case .valid(let value):
                    values[stage] = value
                case .invalid(let kind):
                    report(kind, line: stageEntry.value.line, key: target)
                }
            }
            return .perStage(values)
        case .invalid:
            return nil
        case .null, .sequence:
            report(.wrongType(field: entry.key, expected: .textOrMapping), line: node.line, key: target)
            return nil
        }
    }

    // MARK: - Variables

    private mutating func mapVars(_ entry: ManifestEntry, targets: [ManifestTargetModel]) -> [ManifestVarModel]? {
        guard let entries = mapping(entry.value, field: ManifestField.vars, key: nil) else { return nil }
        guard entries.count <= EnvToolsLimits.maxManifestVars else {
            report(.tooManyVars(limit: EnvToolsLimits.maxManifestVars), line: entry.value.line)
            return nil
        }
        let providers = Dictionary(targets.map { ($0.name, $0.provider) }, uniquingKeysWith: { first, _ in first })
        return entries.compactMap { mapVar($0, providers: providers) }
    }

    private mutating func mapVar(_ entry: ManifestEntry, providers: [String: ManifestProvider]) -> ManifestVarModel? {
        let name = entry.key
        if let rule = GitHubNameValidator.violation(in: name) {
            report(.invalidVarName(rule), line: entry.keyLine, key: name)
            return nil
        }
        guard GitHubNameValidator.normalize(name) == name else {
            report(.varNameNotUppercase, line: entry.keyLine, key: name)
            return nil
        }
        guard let fields = mapping(entry.value, field: nil, key: name) else { return nil }
        for field in fields where !ManifestField.variable.contains(field.key) {
            report(.unknownField(field.key), line: field.keyLine, key: name)
        }
        let lookup = Self.lookup(fields)
        var isUsable = true

        let isSecret = flag(ManifestField.secret, in: lookup, key: name, isUsable: &isUsable)
        let isPublic = flag(ManifestField.isPublic, in: lookup, key: name, isUsable: &isUsable)
        if isSecret, isPublic {
            report(.secretAndPublic, line: entry.keyLine, key: name)
            isUsable = false
        }
        let targets = targetReferences(lookup, variable: entry, providers: providers, isUsable: &isUsable)
        let stages = stageReferences(lookup, variable: name, isUsable: &isUsable)
        guard isUsable else { return nil }

        let kind: ManifestVarKind = isSecret ? .secret : (isPublic ? .publicVariable : .variable)
        let destinations = Set(targets.compactMap { providers[$0] })
        if kind == .secret, destinations.contains(.vercel), let prefix = PublicNamePrefixes.prefix(of: name) {
            report(.publicPrefixOnSecret(prefix: prefix), line: entry.keyLine, key: name)
        }
        if destinations.contains(.supabase), name.hasPrefix(DestinationRules.supabaseReservedPrefix) {
            report(.reservedSupabasePrefix, line: entry.keyLine, key: name)
        }
        return ManifestVarModel(name: name, kind: kind, targets: targets, stages: stages, line: entry.keyLine)
    }

    /// An optional boolean field: false when absent.
    private mutating func flag(
        _ field: String,
        in lookup: [String: ManifestEntry],
        key: String,
        isUsable: inout Bool
    ) -> Bool {
        guard let entry = lookup[field] else { return false }
        guard let value = boolean(entry.value, field: field, key: key) else {
            isUsable = false
            return false
        }
        return value
    }

    /// The `to` list: defined targets in order, without repeats.
    private mutating func targetReferences(
        _ lookup: [String: ManifestEntry],
        variable: ManifestEntry,
        providers: [String: ManifestProvider],
        isUsable: inout Bool
    ) -> [String] {
        let name = variable.key
        guard let entry = lookup[ManifestField.to] else {
            report(.missingField(ManifestField.to), line: variable.keyLine, key: name)
            isUsable = false
            return []
        }
        guard let nodes = sequence(entry.value, field: ManifestField.to, key: name) else {
            isUsable = false
            return []
        }
        if nodes.isEmpty { report(.noTargets, line: entry.value.line, key: name) }
        var targets: [String] = []
        var seen: Set<String> = []
        for node in nodes {
            guard let target = text(node, field: ManifestField.to, key: name) else { continue }
            guard seen.insert(target).inserted else {
                report(.duplicateReference(target), line: node.line, key: name)
                continue
            }
            if providers[target] != nil {
                targets.append(target)
            } else if !droppedTargetNames.contains(target) {
                report(.undefinedTarget(target), line: node.line, key: name)
            }
        }
        // Every reference was reported, or points at a target whose own issue explains it.
        if targets.isEmpty { isUsable = false }
        return targets
    }

    /// The optional `stages` list: declared stages (declared spellings) in order, or nil for
    /// every stage.
    private mutating func stageReferences(
        _ lookup: [String: ManifestEntry],
        variable name: String,
        isUsable: inout Bool
    ) -> [String]? {
        guard let entry = lookup[ManifestField.stages] else { return nil }
        guard let nodes = sequence(entry.value, field: ManifestField.stages, key: name) else {
            isUsable = false
            return nil
        }
        if nodes.isEmpty { report(.noStages, line: entry.value.line, key: name) }
        var stages: [String] = []
        for node in nodes {
            guard let text = text(node, field: ManifestField.stages, key: name) else { continue }
            guard let stage = declaredStage(text) else {
                report(.undeclaredStage(text), line: node.line, key: name)
                continue
            }
            guard !stages.contains(stage) else {
                report(.duplicateReference(text), line: node.line, key: name)
                continue
            }
            stages.append(stage)
        }
        if stages.isEmpty { isUsable = false }
        return stages
    }

    // MARK: - Typed access

    private mutating func mapping(_ node: ManifestNode, field: String?, key: String?) -> [ManifestEntry]? {
        switch node.value {
        case .mapping(let entries):
            return entries
        case .invalid:
            return nil
        case .scalar, .sequence, .null:
            report(.wrongType(field: field, expected: .mapping), line: node.line, key: key)
            return nil
        }
    }

    private mutating func sequence(_ node: ManifestNode, field: String, key: String?) -> [ManifestNode]? {
        switch node.value {
        case .sequence(let items):
            return items
        case .invalid:
            return nil
        case .scalar, .mapping, .null:
            report(.wrongType(field: field, expected: .sequence), line: node.line, key: key)
            return nil
        }
    }

    /// Any scalar, quoted or plain (so `stages: [2024]` names a stage "2024").
    private mutating func text(_ node: ManifestNode, field: String, key: String?) -> String? {
        switch node.value {
        case .scalar(let text, _):
            return text
        case .invalid:
            return nil
        case .mapping, .sequence, .null:
            report(.wrongType(field: field, expected: .text), line: node.line, key: key)
            return nil
        }
    }

    /// Unquoted `true` or `false`.
    private mutating func boolean(_ node: ManifestNode, field: String, key: String?) -> Bool? {
        switch node.value {
        case .scalar(Self.trueLiteral, .plain):
            return true
        case .scalar(Self.falseLiteral, .plain):
            return false
        case .invalid:
            return nil
        default:
            report(.wrongType(field: field, expected: .boolean), line: node.line, key: key)
            return nil
        }
    }

    /// An unquoted decimal integer (an optional sign, then digits).
    private mutating func integer(_ node: ManifestNode, field: String, key: String?) -> Int? {
        switch node.value {
        case .scalar(let text, .plain):
            if let value = Int(text) { return value }
        case .invalid:
            return nil
        default:
            break
        }
        report(.wrongType(field: field, expected: .integer), line: node.line, key: key)
        return nil
    }

    private static let trueLiteral = "true"
    private static let falseLiteral = "false"

    /// Entries by key (the reader already dropped duplicates).
    private static func lookup(_ entries: [ManifestEntry]) -> [String: ManifestEntry] {
        Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private mutating func report(_ kind: ManifestIssue.Kind, line: Int, key: String? = nil) {
        issues.append(.sanitized(line: line, kind: kind, key: key))
    }
}
