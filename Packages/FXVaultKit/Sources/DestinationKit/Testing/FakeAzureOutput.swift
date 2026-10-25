import Foundation

/// What `az` prints, for `FakeCommandRunner` stubs (AppTests and the UI-testing host, which
/// never run a real `az`), and the Key Vault answers for ``FakeHTTPTransport``. Synthetic names
/// and tokens only.
public enum FakeAzureOutput {
    public struct Subscription: Sendable {
        public let id: UUID
        public let name: String
        public let tenantID: UUID
        public let state: String
        public let isDefault: Bool

        public init(id: UUID, name: String, tenantID: UUID, state: String = "Enabled", isDefault: Bool = false) {
            self.id = id
            self.name = name
            self.tenantID = tenantID
            self.state = state
            self.isDefault = isDefault
        }
    }

    /// `00000000-0000-0000-0000-0000000000<last>`: a synthetic subscription or tenant id built
    /// without parsing, so callers need no force unwrap.
    public static func syntheticID(_ last: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, last))
    }

    /// `az account list --output json`.
    public static func accountList(_ subscriptions: [Subscription]) -> String {
        let entries = subscriptions.map { subscription in
            """
            {"cloudName":"AzureCloud","id":"\(subscription.id.uuidString.lowercased())","isDefault":\(subscription.isDefault),\
            "name":"\(subscription.name)","state":"\(subscription.state)","tenantId":"\(subscription.tenantID.uuidString.lowercased())",\
            "user":{"name":"user-a@example.com","type":"user"}}
            """
        }
        return "[\(entries.joined(separator: ","))]"
    }

    /// `az keyvault list --resource-type vault --subscription <id> --output json`.
    public static func keyVaultList(_ names: [String], subscriptionID: UUID, location: String = "westeurope") -> String {
        let subscription = subscriptionID.uuidString.lowercased()
        let entries = names.map { name in
            """
            {"id":"/subscriptions/\(subscription)/resourceGroups/rg-\(name)/providers/Microsoft.KeyVault/vaults/\(name)",\
            "location":"\(location)","name":"\(name)","resourceGroup":"rg-\(name)",\
            "properties":{"vaultUri":"https://\(name).vault.azure.net/"},"type":"Microsoft.KeyVault/vaults"}
            """
        }
        return "[\(entries.joined(separator: ","))]"
    }

    /// `az account get-access-token`: a synthetic token that expires `expiresOn`.
    public static func accessToken(expiresOn: Date) -> String {
        let epoch = Int(expiresOn.timeIntervalSince1970)
        return #"{"accessToken":"fake-azure-token","expires_on":\#(epoch),"tokenType":"Bearer"}"#
    }

    /// One page of Key Vault's `GET /secrets` listing `names` (remote names, `DATABASE-URL`).
    public static func secretList(vaultName: String, names: [String]) -> String {
        let entries = names.map { name in
            #"{"id":"https://\#(vaultName).vault.azure.net/secrets/\#(name)","attributes":{"enabled":true,"created":1789990000,"updated":1790000000}}"#
        }
        return #"{"value":[\#(entries.joined(separator: ","))],"nextLink":null}"#
    }

    /// Key Vault's `GET /secrets/<name>` with `value`.
    public static func secret(vaultName: String, name: String, value: String) -> String {
        #"{"value":"\#(value)","id":"https://\#(vaultName).vault.azure.net/secrets/\#(name)/0f1e2d3c4b5a69788796a5b4c3d2e1f0","attributes":{"enabled":true,"created":1789990000,"updated":1790000000}}"#
    }
}

extension FakeHTTPTransport {
    /// Answers one vault's listing and reads: `secrets` maps remote names (`DATABASE-URL`) to
    /// values. Every request for another host stays unmatched.
    public func stubKeyVault(_ vaultName: String, secrets: [String: String]) {
        let host = DestinationHostPolicy.keyVaultHost(vaultName: vaultName)
        stub(.json(FakeAzureOutput.secretList(vaultName: vaultName, names: secrets.keys.sorted())), method: .get, pathPrefix: "/secrets", host: host)
        for (name, value) in secrets {
            stub(.json(FakeAzureOutput.secret(vaultName: vaultName, name: name, value: value)), method: .get, pathPrefix: "/secrets/\(name)", host: host)
        }
    }
}
