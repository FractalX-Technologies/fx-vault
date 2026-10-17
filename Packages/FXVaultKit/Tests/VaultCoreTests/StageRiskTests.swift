import Foundation
import Testing
@testable import VaultCore

@Suite("Stage risk and share expiry")
struct StageRiskTests {
    @Test(arguments: ["prod", "Production", "PRD", "live", "prod-eu", "eu_prod", "live 2", "Staging / Prod", "prod2"])
    func productionStages(_ stage: String) {
        #expect(StageRisk.isProduction(stage))
    }

    @Test(arguments: ["product", "preview", "reproduce", "staging", "development", "delivery", "", "products"])
    func otherStages(_ stage: String) {
        #expect(!StageRisk.isProduction(stage))
    }

    @Test func expiryChoicesAddWholeDays() {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ShareExpiryChoice.default == .sevenDays)
        #expect(ShareExpiryChoice.oneDay.expiry(from: createdAt).timeIntervalSince(createdAt) == 86_400)
        #expect(ShareExpiryChoice.thirtyDays.duration == Timeouts.shareMaxExpiry)
    }

    @Test func formatTwoFileBoundCoversTenRecipients() {
        #expect(Limits.shareRecipientSlotBytes == 88)
        #expect(Limits.maxShareFileV2Bytes - Limits.maxShareFileBytes
            == Limits.maxShareRecipients * Limits.shareRecipientSlotBytes + Limits.shareSenderPrefixBytes)
    }
}
