import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import NoteCore

/// A direct HTML editor: the binding remains the original server HTML until a real edit.
struct OriginalHTMLEditor: NSViewRepresentable {
    @Binding var html: String
    let attachments: [NoteAttachment]
    let assetStore: AttachmentStore
    var isEditable: Bool
    let undoManager: UndoManager
    var onFiles: ([URL]) -> Void
    var onImage: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> OriginalEditorWebView { context.coordinator.makeWebView() }
    func updateNSView(_ web: OriginalEditorWebView, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ web: OriginalEditorWebView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: OriginalHTMLEditor
        private(set) var revision = 0
        private(set) var isReady = false
        private(set) var loadingError: Error?
        private var lastHTML: String?
        private var lastAttachments: [NoteAttachment] = []
        private var lastEditable = false
        private var pageLoaded = false
        private var detached = false
        private var lifetime = UUID()
        private var composing = false
        private var pendingUpdate = false
        private var pendingHistory: String?
        private var navigation: WKNavigation?
        private weak var web: OriginalEditorWebView?
        private var schemeHandler: OriginalAttachmentSchemeHandler?
        private var bridge: OriginalEditorMessageBridge?
        private weak var panel: NSOpenPanel?
        init(_ parent: OriginalHTMLEditor) { self.parent = parent }

        func makeWebView() -> OriginalEditorWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            let scheme = OriginalAttachmentSchemeHandler(store: parent.assetStore)
            scheme.attachments = parent.attachments
            schemeHandler = scheme
            configuration.setURLSchemeHandler(scheme, forURLScheme: "attachment")
            let bridge = OriginalEditorMessageBridge(self)
            self.bridge = bridge
            configuration.userContentController.add(bridge, contentWorld: OriginalEditorRuntime.world, name: "originalEditor")
            let web = OriginalEditorWebView(frame: .zero, configuration: configuration)
            self.web = web
            web.noteUndoManager = parent.undoManager
            web.navigationDelegate = self
            web.setAccessibilityLabel(appText("Original HTML Editor"))
            web.registerForDraggedTypes([.fileURL, .png, .tiff])
            navigation = web.loadHTMLString(OriginalEditorRuntime.page, baseURL: URL(string: "about:blank"))
            update(parent)
            return web
        }

        func update(_ next: OriginalHTMLEditor) {
            guard !detached else { return }
            let identityChanged = parent.undoManager !== next.undoManager || parent.assetStore !== next.assetStore
            if identityChanged {
                parent.undoManager.removeAllActions(withTarget: self)
                lifetime = UUID()
            }
            parent = next
            web?.noteUndoManager = next.undoManager
            web?.historyAllowed = { [weak self] in
                guard let self else { return false }
                return !self.detached && self.isReady && self.parent.isEditable && !self.composing
            }
            web?.isEditorEditable = next.isEditable
            web?.onFiles = { [weak self] urls in
                guard let self, !self.detached, self.parent.isEditable, !self.composing else { return }
                self.parent.onFiles(urls)
            }
            web?.onImage = { [weak self] data in
                guard let self, !self.detached, self.parent.isEditable, !self.composing else { return }
                self.parent.onImage(data)
            }
            if identityChanged { schemeHandler?.store = next.assetStore }
            schemeHandler?.attachments = next.attachments
            // Do not replace marked Korean text when a background attachment or
            // model refresh reaches SwiftUI. Apply it after composition commits.
            if composing && !identityChanged && next.isEditable { pendingUpdate = true; return }
            if lastHTML != next.html || identityChanged {
                next.undoManager.removeAllActions(withTarget: self)
                lifetime = UUID()
                pendingHistory = nil
                lastHTML = next.html
                lastAttachments = next.attachments
                lastEditable = next.isEditable
                reload()
            } else if lastAttachments != next.attachments {
                lastAttachments = next.attachments
                if isReady {
                    web?.callAsyncJavaScript("return window.originalEditor.updateAttachments(attachments)", arguments: ["attachments": attachmentArguments], in: nil, in: OriginalEditorRuntime.world) { _ in }
                } else { reload() }
            }
            if lastEditable != next.isEditable {
                lastEditable = next.isEditable
                web?.callAsyncJavaScript("window.originalEditor?.setEditable(enabled); return true", arguments: ["enabled": next.isEditable], in: nil, in: OriginalEditorRuntime.world) { _ in }
            }
        }

        private var attachmentArguments: [[String: String]] {
            parent.attachments.map {
                var result = ["reference": $0.reference, "name": $0.name]
                result["remoteID"] = $0.remoteID
                result["remoteReference"] = $0.remoteReference
                return result
            }
        }
        private func reload() {
            revision += 1
            isReady = false
            loadingError = nil
            composing = false
            guard pageLoaded, let web, !detached else { return }
            let currentRevision = revision
            let assets = attachmentArguments
            web.callAsyncJavaScript(OriginalEditorRuntime.script + "\nreturn window.originalEditor.load(html, attachments, editable, revision);",
                                    arguments: ["html": parent.html, "attachments": assets, "editable": parent.isEditable,
                                                "revision": currentRevision, "labels": OriginalEditorRuntime.labels],
                                    in: nil, in: OriginalEditorRuntime.world) { [weak self] result in
                guard let self, !self.detached, self.revision == currentRevision else { return }
                switch result {
                case .success: self.isReady = true
                case .failure(let error): self.loadingError = error
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === self.navigation, !detached else { return }
            pageLoaded = true
            reload()
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The sole allowed navigation is our initial, host-created blank document.
            let initial = !pageLoaded && action.navigationType == .other && action.request.url?.absoluteString == "about:blank"
            decisionHandler(initial ? .allow : .cancel)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
            receive(body)
        }
        func receive(_ body: [String: Any]) {
            guard !detached, isReady, body["revision"] as? Int == revision, parent.isEditable else { return }
            if let value = body["composing"] as? Bool { composing = value }
            defer {
                if !composing, pendingUpdate { pendingUpdate = false; update(parent) }
            }
            if !composing, let pending = pendingHistory {
                pendingHistory = nil
                guard parent.html == lastHTML else { update(parent); return }
                lastHTML = pending
                parent.html = pending
                reload()
                return
            }
            if let action = body["action"] as? String {
                switch action {
                case "undo": if !composing { parent.undoManager.undo() }
                case "redo": if !composing { parent.undoManager.redo() }
                case "pasteFiles": web?.pasteAttachments(from: NSPasteboard.general)
                case "pickFiles": pickFiles()
                default: break
                }
            }
            guard !composing, let html = body["html"] as? String, let previous = lastHTML, html != previous else { return }
            // A model replacement can precede SwiftUI's next update pass.
            guard parent.html == previous else { update(parent); return }
            registerUndo(restoring: previous)
            lastHTML = html
            parent.html = html
        }
        private func registerUndo(restoring html: String) {
            let currentLifetime = lifetime
            let manager = parent.undoManager
            let needsGroup = manager.groupingLevel == 0
            if needsGroup { manager.beginUndoGrouping() }
            manager.registerUndo(withTarget: self) { target in
                guard !target.detached, target.lifetime == currentLifetime, target.parent.isEditable else { return }
                let current = target.parent.html
                target.registerUndo(restoring: current)
                // The app can invoke the session manager directly while marked
                // text exists. Defer the requested restore until IME finishes.
                if target.composing { target.pendingHistory = html; return }
                target.lastHTML = html
                target.parent.html = html
                target.reload()
            }
            manager.setActionName(appText("Edit Original HTML"))
            if needsGroup { manager.endUndoGrouping() }
        }
        private func pickFiles() {
            guard let web, parent.isEditable, !composing else { return }
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            let expectedLifetime = lifetime
            self.panel = panel
            let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self, !self.detached, self.lifetime == expectedLifetime, self.parent.isEditable, response == .OK else { return }
                self.parent.onFiles(panel.urls)
            }
            if let window = web.window { panel.beginSheetModal(for: window, completionHandler: completion) }
            else { panel.begin(completionHandler: completion) }
        }
        func detach() {
            detached = true
            revision += 1
            isReady = false
            parent.undoManager.removeAllActions(withTarget: self)
            panel?.cancel(nil)
            web?.stopLoading()
            web?.navigationDelegate = nil
            web?.configuration.userContentController.removeScriptMessageHandler(forName: "originalEditor", contentWorld: OriginalEditorRuntime.world)
            web?.onFiles = nil
            web?.onImage = nil
            web?.historyAllowed = nil
            schemeHandler?.cancelAll()
            bridge = nil
        }
    }
}

@MainActor private final class OriginalEditorMessageBridge: NSObject, WKScriptMessageHandler {
    weak var owner: OriginalHTMLEditor.Coordinator?
    init(_ owner: OriginalHTMLEditor.Coordinator) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.userContentController(userContentController, didReceive: message)
    }
}

// Tests can supply an in-memory clipboard without requiring a GUI pasteboard service.
@MainActor protocol OriginalEditorAttachmentClipboard {
    func attachmentFileURLs() -> [URL]
    func attachmentData(forType type: NSPasteboard.PasteboardType) -> Data?
}

extension NSPasteboard: OriginalEditorAttachmentClipboard {
    func attachmentFileURLs() -> [URL] {
        readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    func attachmentData(forType type: NSPasteboard.PasteboardType) -> Data? { data(forType: type) }
}

@MainActor final class OriginalEditorWebView: WKWebView {
    var noteUndoManager: UndoManager? { didSet { undoBridge.session = noteUndoManager } }
    // WebKit registers its own DOM commands asynchronously. They must never enter
    // the model's undo stack alongside our HTML snapshots. Menu/key commands still
    // reach that same session stack through this responder-chain bridge.
    private let undoBridge = OriginalEditorUndoBridge()
    var historyAllowed: (() -> Bool)? { didSet { undoBridge.isAllowed = historyAllowed } }
    override var undoManager: UndoManager? { undoBridge }
    var isEditorEditable = false
    var onFiles: (([URL]) -> Void)?
    var onImage: ((Data) -> Void)?
    @discardableResult func pasteAttachments(from clipboard: any OriginalEditorAttachmentClipboard) -> Bool {
        guard isEditorEditable else { return false }
        let files = clipboard.attachmentFileURLs()
        if !files.isEmpty { onFiles?(files); return true }
        if let png = clipboard.attachmentData(forType: .png) { onImage?(png); return true }
        if let tiff = clipboard.attachmentData(forType: .tiff), let image = NSBitmapImageRep(data: tiff), let png = image.representation(using: .png, properties: [:]) { onImage?(png); return true }
        return false
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v", pasteAttachments(from: NSPasteboard.general) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isEditorEditable else { return [] }
        let pasteboard = sender.draggingPasteboard
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) || pasteboard.availableType(from: [.png, .tiff]) != nil ? .copy : []
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { pasteAttachments(from: sender.draggingPasteboard) }
}

@MainActor private final class OriginalEditorUndoBridge: UndoManager {
    weak var session: UndoManager?
    var isAllowed: (() -> Bool)?
    override init() { super.init(); disableUndoRegistration() }
    override var canUndo: Bool { (isAllowed?() ?? false) && (session?.canUndo ?? false) }
    override var canRedo: Bool { (isAllowed?() ?? false) && (session?.canRedo ?? false) }
    override var undoActionName: String { session?.undoActionName ?? "" }
    override var redoActionName: String { session?.redoActionName ?? "" }
    override func undo() { if canUndo { session?.undo() } }
    override func redo() { if canRedo { session?.redo() } }
}

@MainActor private final class OriginalAttachmentSchemeHandler: NSObject, WKURLSchemeHandler {
    var store: AttachmentStore
    var attachments: [NoteAttachment] = []
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(store: AttachmentStore) { self.store = store }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard let url = urlSchemeTask.request.url, let id = UUID(uuidString: url.host ?? ""),
              let attachment = attachments.first(where: { $0.id == id }) else { urlSchemeTask.didFailWithError(AttachmentError.missing); return }
        let store = store
        tasks[key] = Task { [weak self] in
            defer { self?.tasks.removeValue(forKey: key) }
            do {
                let data = try await store.verifiedData(for: attachment)
                guard !Task.isCancelled else { return }
                let mime = UTType(filenameExtension: (attachment.name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch { if !Task.isCancelled { urlSchemeTask.didFailWithError(error) } }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.cancel() }
    func cancelAll() { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
}
