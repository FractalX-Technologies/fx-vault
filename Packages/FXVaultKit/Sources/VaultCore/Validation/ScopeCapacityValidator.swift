/// GitHub's item limits per scope (§7.3 preflight, §9.3): 100 secrets per repository or
/// environment, 500 variables per repository and 100 per environment.
public enum ScopeCapacityValidator {
    /// Throws ``ValidationError/scopeFull(kind:limit:)`` when adding `adding` items of `kind` to a
    /// scope that already holds `currentCount` (non-deleted) items would exceed the limit.
    public static func validate(
        currentCount: Int,
        adding: Int = 1,
        kind: ConfigKind,
        level: ConfigScopeLevel
    ) throws(ValidationError) {
        let limit = Limits.maxItems(kind: kind, level: level)
        if currentCount + adding > limit {
            throw .scopeFull(kind: kind, limit: limit)
        }
    }

    /// Items of `kind` that still fit in a scope holding `currentCount`.
    public static func remainingCapacity(
        currentCount: Int,
        kind: ConfigKind,
        level: ConfigScopeLevel
    ) -> Int {
        max(0, Limits.maxItems(kind: kind, level: level) - currentCount)
    }
}
