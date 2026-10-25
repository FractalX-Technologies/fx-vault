import AppKit
import Foundation
import SwiftUI
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Rendered PNGs of organization editing (1.0, B6b3a): the detail with pending changes and the
/// item editor on a Selected secret. Opt-in like ``VisualSnapshotTests`` (`FXV_SNAPSHOTS_DIR`,
/// or `TEST_RUNNER_FXV_SNAPSHOTS_DIR` through xcodebuild). Nothing is asserted about pixels.
@MainActor
@Suite("Organization snapshots", .serialized, .enabled(if: SnapshotOutput.directory != nil, "set FXV_SNAPSHOTS_DIR to render"))
struct OrganizationSnapshotTests {
    private static let sheetSize = CGSize(width: Theme.Layout.editorSheetWidth, height: SnapshotOutput.tallSheetHeight)

    @Test func organizationDetail() async throws {
        let (harness, organization) = try await OrganizationEditingTests().imported()
        let items = harness.data.organizationItems
        let npm = try #require(try await harness.data.organizations.items(of: organization.id).first { $0.name == "NPM_TOKEN" })
        try items.deleteItems([npm.id])
        let bytes = SecretBytes(utf8: "eu-west-1")
        try items.addItem(organizationID: organization.id, kind: .variable, name: "ZONE", value: bytes, access: .selected(["web"]))
        let main = harness.app.makeMainViewModel()
        let detail = OrganizationDetailViewModel(
            organizationID: organization.id,
            dependencies: harness.dependencies(recorder: ActionRecorder()),
            organization: { organization },
            repositoryNames: { [] }
        )
        #expect(await TestFixtures.eventually { detail.items.count == 4 })
        try await SnapshotOutput.write("organization-detail", size: SnapshotOutput.windowSize) {
            OrganizationDetailScreen(viewModel: detail, main: main)
        }
    }

    @Test func organizationItemEditor() async throws {
        let (harness, organization) = try await OrganizationEditingTests().imported()
        let stripe = try #require(try await harness.data.organizations.items(of: organization.id).first { $0.name == "STRIPE_KEY" })
        let editor = await OrganizationEditingTests().makeEditor(harness, organization, .edit(stripe.id))
        editor.setRepository("web", selected: true)
        #expect(editor.canSave)
        try await SnapshotOutput.write("organization-item-editor", size: Self.sheetSize) {
            OrgItemEditorScreen(viewModel: editor)
        }
    }
}
