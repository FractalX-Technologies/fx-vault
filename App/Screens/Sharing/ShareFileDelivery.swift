import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// How a sharing-picker hand-off ended.
enum ShareDeliveryOutcome: Equatable {
    case shared
    case cancelled
    case failed
}

/// Where a finished `.fxvault` file goes (§9.1 writer): a save panel, or the system sharing
/// picker (AirDrop). A protocol so view-model tests never open a panel.
protocol ShareFileDelivering: AnyObject {
    /// Asks where to save; nil when the user cancelled. The panel already confirmed replacing an
    /// existing file.
    func chooseSaveDestination(suggestedName: String) async -> URL?
    /// Offers `fileURL` to the sharing services (AirDrop, Mail, Messages). `completion` runs once.
    func share(fileURL: URL, completion: @escaping (ShareDeliveryOutcome) -> Void)
    /// Whether this Mac offers AirDrop for `fileURL` (off, or no Wi-Fi or Bluetooth hardware).
    func canSendWithAirDrop(fileURL: URL) -> Bool
    /// Opens the system AirDrop window for `fileURL` (Send with AirDrop, 1.0). `completion` runs
    /// once.
    func sendWithAirDrop(fileURL: URL, completion: @escaping (ShareDeliveryOutcome) -> Void)
}

/// `NSSavePanel` and `NSSharingServicePicker`, anchored to the view ``ShareDeliveryAnchor``
/// registers.
final class SystemShareFileDelivery: NSObject, ShareFileDelivering, NSSharingServicePickerDelegate,
    NSSharingServiceDelegate {
    /// The view the panel and the picker attach to (the sheet's delivery buttons).
    weak var anchorView: NSView?
    private var completion: ((ShareDeliveryOutcome) -> Void)?
    private var picker: NSSharingServicePicker?

    /// The exported `.fxvault` type (Info.plist `UTExportedTypeDeclarations`).
    static let shareFileType = UTType(exportedAs: "io.fractalx.fxvault.share")

    func chooseSaveDestination(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [Self.shareFileType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let response = if let window = anchorView?.window {
            await panel.beginSheetModal(for: window)
        } else {
            panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }

    func share(fileURL: URL, completion: @escaping (ShareDeliveryOutcome) -> Void) {
        guard let anchorView else {
            completion(.failed)
            return
        }
        finish(.cancelled)
        let picker = NSSharingServicePicker(items: [fileURL])
        picker.delegate = self
        self.picker = picker
        self.completion = completion
        picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    func canSendWithAirDrop(fileURL: URL) -> Bool {
        NSSharingService(named: .sendViaAirDrop)?.canPerform(withItems: [fileURL]) == true
    }

    func sendWithAirDrop(fileURL: URL, completion: @escaping (ShareDeliveryOutcome) -> Void) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [fileURL]) else {
            completion(.failed)
            return
        }
        finish(.cancelled)
        self.completion = completion
        service.delegate = self
        service.perform(withItems: [fileURL])
    }

    private func finish(_ outcome: ShareDeliveryOutcome) {
        let completion = completion
        self.completion = nil
        picker = nil
        completion?(outcome)
    }

    // MARK: - NSSharingServicePickerDelegate

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service == nil {
            finish(.cancelled)
        }
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        self
    }

    // MARK: - NSSharingServiceDelegate

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish(.shared)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        let cancelled = (error as NSError).code == NSUserCancelledError
        finish(cancelled ? .cancelled : .failed)
    }
}

/// Registers its `NSView` as the anchor of a ``SystemShareFileDelivery``.
struct ShareDeliveryAnchor: NSViewRepresentable {
    let delivery: any ShareFileDelivering

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        (delivery as? SystemShareFileDelivery)?.anchorView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (delivery as? SystemShareFileDelivery)?.anchorView = view
    }
}
