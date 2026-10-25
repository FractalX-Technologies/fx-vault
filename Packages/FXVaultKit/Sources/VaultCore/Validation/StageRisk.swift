import Foundation

/// Which stages count as production when sharing (v0.9.0, P2): 1.0 never shares them (Q13).
public enum StageRisk {
    /// The words that mark a production stage, lowercase.
    public static let productionWords: Set<String> = ["prod", "production", "prd", "live"]

    /// True when any word of `stage`, split on everything that is not a letter, is one of
    /// ``productionWords`` (ignoring case): `Production`, `prod-eu` and `live_2` are production;
    /// `product`, `preview` and `reproduce` are not.
    public static func isProduction(_ stage: String) -> Bool {
        stage
            .lowercased()
            .split { !$0.isLetter }
            .contains { productionWords.contains(String($0)) }
    }
}
