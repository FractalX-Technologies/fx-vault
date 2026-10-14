/// Shared duplicate check for names compared by fold key (§7.1 editing rules).
public enum NameAvailability {
    /// Throws ``ValidationError/duplicateName`` when `key` is in `takenKeys`, then
    /// ``ValidationError/nameReservedByPendingChange`` when it is in `reservedKeys`.
    ///
    /// Callers fold every key with the same validator's `foldKey(_:)` and leave the row being
    /// edited out of both sets.
    public static func check(
        key: String,
        takenKeys: Set<String>,
        reservedKeys: Set<String>
    ) throws(ValidationError) {
        if takenKeys.contains(key) { throw .duplicateName }
        if reservedKeys.contains(key) { throw .nameReservedByPendingChange }
    }
}
