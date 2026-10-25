import Foundation

/// One page of B14/B15 `orgs/{o}/actions/{secrets|variables}/{n}/repositories`: only the names
/// are read (the organization is the owner of every one).
struct GHSelectedRepositoriesPageDTO: Decodable {
    let totalCount: Int
    let repositories: [Repository]

    struct Repository: Decodable {
        let name: String
    }

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case repositories
    }
}
