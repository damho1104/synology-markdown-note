import AppKit
import SwiftUI
import NoteCore

@MainActor final class EditorPosition {
    var selection = NSRange(location: 0, length: 0)
    var scroll = NSPoint.zero
    weak var editor: SourceTextView?
}

private extension NSAttributedString.Key { static let originalBlockToken = NSAttributedString.Key("SynologyNote.originalBlockToken") }

/// Keep the popup beside the insertion point, preferring below the current line.
/// The caller supplies both rectangles in the same AppKit view coordinate space.
enum NoteCompletionPlacement {
    static func frame(caret: NSRect, within bounds: NSRect, size: NSSize, flipped: Bool,
                      margin: CGFloat = 8, gap: CGFloat = 6) -> NSRect {
        let width = min(size.width, max(0, bounds.width - 2 * margin))
        let height = min(size.height, max(0, bounds.height - 2 * margin))
        let x = min(max(caret.maxX + gap, bounds.minX + margin), bounds.maxX - margin - width)
        let below = flipped ? caret.maxY + gap : caret.minY - height - gap
        let fitsBelow = flipped ? below + height <= bounds.maxY - margin : below >= bounds.minY + margin
        let above = flipped ? caret.minY - height - gap : caret.maxY + gap
        let y = min(max(fitsBelow ? below : above, bounds.minY + margin), bounds.maxY - margin - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

struct MarkdownEditor: NSViewRepresentable {
    @AppStorage("editorFontSize") private var fontSize = 14.0
    @Binding var text: String
    let blocks: [PreservedBlock]
    let position: EditorPosition
    let undoManager: UndoManager
    var isEditable: Bool
    var onSourceLine: ((Int) -> Void)? = nil
    var linkCandidates: [NoteSummary] = []
    var linkNotebooks: [Notebook] = []
    var onFiles: ([URL]) -> Void
    var onImage: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = SourceTextView()
        editor.noteUndoManager = undoManager
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 26, height: 20)
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.onFiles = onFiles; editor.onImage = onImage
        editor.registerForDraggedTypes([.fileURL, .png, .tiff])
        editor.setAccessibilityLabel("Markdown 본문")
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.autohidesScrollers = true
        context.coordinator.editor = editor
        context.coordinator.observeUndo(undoManager)
        position.editor = editor
        editor.onCompletionKey = { [weak coordinator = context.coordinator] key in coordinator?.handleCompletionKey(key) ?? false }
        context.coordinator.replace(with: text, blocks: blocks)
        editor.setSelectedRange(clamped(position.selection, length: editor.string.utf16.count))
        scroll.contentView.scroll(to: position.scroll)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? SourceTextView else { return }
        context.coordinator.parent = self
        position.editor = editor
        editor.isEditable = isEditable
        editor.onFiles = onFiles; editor.onImage = onImage
        if editor.sourceText != text, !editor.hasMarkedText() {
            context.coordinator.replace(with: text, blocks: blocks)
        }
        context.coordinator.style()
        context.coordinator.positionCompletion()
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let editor = scroll.documentView as? SourceTextView {
            coordinator.parent.position.selection = editor.selectedRange()
            coordinator.parent.position.scroll = scroll.contentView.bounds.origin
        }
        coordinator.hideCompletion()
        coordinator.stopObservingUndo()
        coordinator.parent.position.editor = nil
    }
    private func clamped(_ range: NSRange, length: Int) -> NSRange { NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location))) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var editor: SourceTextView?
        var updating = false
        private var completion: InternalNoteLinks.Completion?
        private var completionView: NSHostingView<NoteLinkPicker>?
        private var completionModel: NoteLinkPickerModel?
        private weak var completionScroll: NSScrollView?
        private var lastStyledText: String?
        private var lastStyledFontSize: Double?
        private weak var observedUndoManager: UndoManager?
        // An Escape dismissal belongs to a specific [[ opening, not to every later edit.
        private var dismissedOpening: Int?
        init(_ parent: MarkdownEditor) { self.parent = parent }

        func observeUndo(_ manager: UndoManager) {
            observedUndoManager = manager
            NotificationCenter.default.addObserver(self, selector: #selector(restyleAfterUndo),
                                                   name: .NSUndoManagerDidUndoChange, object: manager)
            NotificationCenter.default.addObserver(self, selector: #selector(restyleAfterUndo),
                                                   name: .NSUndoManagerDidRedoChange, object: manager)
        }
        func stopObservingUndo() {
            if let manager = observedUndoManager {
                NotificationCenter.default.removeObserver(self, name: .NSUndoManagerDidUndoChange, object: manager)
                NotificationCenter.default.removeObserver(self, name: .NSUndoManagerDidRedoChange, object: manager)
            }
            observedUndoManager = nil
        }
        @objc private func restyleAfterUndo(_ notification: Notification) {
            style()
        }

        func textDidChange(_ notification: Notification) {
            guard !updating, let editor else { return }
            // Never replace or restyle marked text during Korean IME composition.
            parent.text = editor.sourceText
            parent.position.selection = editor.selectedRange()
            reportSourceLine()
            if !editor.hasMarkedText() { style() }
            if !editor.hasMarkedText() { refreshCompletion() }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor else { return }
            parent.position.selection = editor.selectedRange()
            parent.position.scroll = editor.enclosingScrollView?.contentView.bounds.origin ?? .zero
            if !updating && !editor.hasMarkedText() { reportSourceLine(); refreshCompletion() }
        }
        private func reportSourceLine() {
            guard !updating, let editor, editor.isEditable, !editor.hasMarkedText(),
                  editor.window?.firstResponder === editor else { return }
            let range = NSRange(location: 0, length: min(editor.selectedRange().location, editor.attributedString().length))
            let prefix = SourceTextView.source(from: editor.attributedString().attributedSubstring(from: range))
            parent.onSourceLine?(prefix.components(separatedBy: "\n").count)
        }
        func refreshCompletion() {
            guard let editor, editor.isEditable, !editor.hasMarkedText() else { hideCompletion(); return }
            guard editor.selectedRange().length == 0,
                  let candidate = InternalNoteLinks.completion(in: editor.string, caret: editor.selectedRange().location) else {
                hideCompletion()
                dismissedOpening = nil
                return
            }
            guard candidate.range.location != dismissedOpening else { hideCompletion(); return }
            if completion?.range.location != candidate.range.location { hideCompletion() }
            completion = candidate
            if completionModel == nil {
                let model = NoteLinkPickerModel(candidates: parent.linkCandidates, notebooks: parent.linkNotebooks, query: candidate.query)
                completionModel = model
                let view = NSHostingView(rootView: NoteLinkPicker(model: model, searchField: false,
                    onSelect: { [weak self] target in self?.acceptCompletion(target) },
                    onCancel: { [weak self] in self?.dismissCompletion() }))
                completionView = view
                if let scroll = editor.enclosingScrollView {
                    scroll.addSubview(view, positioned: .above, relativeTo: nil)
                    observeCompletionScroll(scroll)
                }
            } else if completionModel?.query != candidate.query {
                completionModel?.query = candidate.query
                completionModel?.selected = 0
            }
            positionCompletion()
        }
        func positionCompletion() {
            guard let editor, let completion, let view = completionView,
                  let scroll = editor.enclosingScrollView, let window = scroll.window else { return }
            let caretOnScreen = editor.firstRect(forCharacterRange: NSRange(
                location: completion.range.location + completion.range.length, length: 0
            ), actualRange: nil)
            let caret = scroll.convert(window.convertFromScreen(caretOnScreen), from: nil)
            view.isHidden = !scroll.bounds.intersects(caret)
            let resultCount = completionModel?.results.count ?? 0
            let popupHeight = min(280, max(100, 24 + CGFloat(resultCount) * 72))
            view.frame = NoteCompletionPlacement.frame(
                caret: caret, within: scroll.bounds, size: NSSize(width: 350, height: popupHeight),
                flipped: scroll.isFlipped
            )
        }
        private func observeCompletionScroll(_ scroll: NSScrollView) {
            completionScroll = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(repositionCompletion),
                                                   name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(repositionCompletion),
                                                   name: NSView.frameDidChangeNotification, object: scroll)
        }
        @objc private func repositionCompletion(_ notification: Notification) {
            positionCompletion()
        }
        func hideCompletion() {
            if let scroll = completionScroll {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: scroll.contentView)
                NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: scroll)
            }
            completionScroll = nil
            completionView?.removeFromSuperview()
            completionView = nil; completionModel = nil; completion = nil
        }
        private func dismissCompletion() {
            dismissedOpening = completion?.range.location
            hideCompletion()
        }
        func handleCompletionKey(_ key: UInt16) -> Bool {
            guard completionView != nil else { return false }
            switch key {
            case 125: completionModel?.step(1)
            case 126: completionModel?.step(-1)
            case 36, 76:
                if let chosen = completionModel?.chosen { acceptCompletion(chosen) }
                else { hideCompletion() }
            case 53: dismissCompletion()
            default: return false
            }
            return true
        }
        private func acceptCompletion(_ target: NoteSummary) {
            guard let editor, let completion, !editor.hasMarkedText(), editor.selectedRange().length == 0,
                  InternalNoteLinks.completion(in: editor.string, caret: editor.selectedRange().location) == completion else {
                hideCompletion(); return
            }
            hideCompletion()
            editor.insertNoteLink(target, replacing: completion.range, label: target.title.isEmpty ? "제목 없음" : target.title)
            editor.window?.makeFirstResponder(editor)
        }
        func replace(with text: String, blocks: [PreservedBlock]) {
            guard let editor else { return }
            updating = true
            defer { updating = false }
            let selection = editor.selectedRange()
            let scroll = editor.enclosingScrollView?.contentView.bounds.origin
            let result = NSMutableAttributedString(string: text)
            for block in blocks {
                let token = MarkdownPipeline.token(for: block)
                var searchRange = NSRange(location: 0, length: result.length)
                while searchRange.location < result.length {
                    let range = (result.string as NSString).range(of: token, range: searchRange)
                    if range.location == NSNotFound { break }
                    let label = "  ▤ \(block.label) · 원본 보존  "
                    let font = NSFont.systemFont(ofSize: 12, weight: .medium)
                    let size = (label as NSString).size(withAttributes: [.font: font])
                    let image = NSImage(size: NSSize(width: size.width + 12, height: 30), flipped: false) { rect in
                        NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
                        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                        (label as NSString).draw(at: NSPoint(x: 6, y: 8), withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                        return true
                    }
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    attachment.bounds = NSRect(x: 0, y: -8, width: image.size.width, height: 30)
                    let folded = NSMutableAttributedString(attachment: attachment)
                    folded.addAttribute(.originalBlockToken, value: token, range: NSRange(location: 0, length: folded.length))
                    result.replaceCharacters(in: range, with: folded)
                    searchRange = NSRange(location: range.location + 1, length: max(0, result.length - range.location - 1))
                }
            }
            editor.textStorage?.setAttributedString(result)
            let length = editor.string.utf16.count
            editor.setSelectedRange(NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location))))
            if let scroll { editor.enclosingScrollView?.contentView.scroll(to: scroll) }
            style()
        }
        func style() {
            guard let editor, !editor.hasMarkedText(), let storage = editor.textStorage else { return }
            let currentText = storage.string
            guard currentText != lastStyledText || parent.fontSize != lastStyledFontSize else { return }
            let range = NSRange(location: 0, length: storage.length)
            // Calculate the desired Markdown appearance separately. Reapplying
            // attributes to the entire live text storage on every keystroke
            // invalidates layout above the caret and moves a scrolled viewport.
            let styled = NSMutableAttributedString(attributedString: storage)
            let font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            styled.addAttributes([.font: font, .foregroundColor: NSColor.textColor], range: range)
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5; paragraph.paragraphSpacing = 2
            styled.addAttribute(.paragraphStyle, value: paragraph, range: range)
            for pattern in ["(?m)^#{1,6} .+$", "(?m)^\\s*(?:[-*+] |[0-9]+\\. |>)", "`[^`]+`", "\\*\\*[^\\n]+?\\*\\*", "\\[[^\\]]*\\]\\([^\\)]+\\)"] {
                if let expression = try? NSRegularExpression(pattern: pattern) {
                    for match in expression.matches(in: currentText, range: range) {
                        styled.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: match.range)
                    }
                }
            }
            // Preserve attachments and originalBlockToken attributes. Only
            // touch runs whose displayed style actually differs.
            var changes: [(NSAttributedString.Key, Any, NSRange)] = []
            for key: NSAttributedString.Key in [.font, .foregroundColor, .paragraphStyle] {
                styled.enumerateAttribute(key, in: range) { value, desiredRange, _ in
                    guard let value else { return }
                    var offset = desiredRange.location
                    while offset < NSMaxRange(desiredRange) {
                        var existingRange = NSRange()
                        let existing = storage.attribute(key, at: offset, effectiveRange: &existingRange)
                        let end = min(NSMaxRange(desiredRange), NSMaxRange(existingRange))
                        if !((existing as? NSObject)?.isEqual(value) ?? false) {
                            changes.append((key, value, NSRange(location: offset, length: end - offset)))
                        }
                        offset = end
                    }
                }
            }
            if !changes.isEmpty {
                storage.beginEditing()
                for (key, value, changedRange) in changes {
                    storage.addAttribute(key, value: value, range: changedRange)
                }
                storage.endEditing()
            }
            editor.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
            lastStyledText = currentText
            lastStyledFontSize = parent.fontSize
        }
    }
}

final class SourceTextView: NSTextView {
    var noteUndoManager: UndoManager?
    override var undoManager: UndoManager? { noteUndoManager ?? super.undoManager }
    var onFiles: (([URL]) -> Void)?
    var onImage: ((Data) -> Void)?
    var onCompletionKey: ((UInt16) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           onCompletionKey?(event.keyCode) == true { return }
        super.keyDown(with: event)
    }
    @discardableResult func insertNoteLink(_ target: NoteSummary, replacing range: NSRange, label: String) -> Bool {
        guard isEditable, !hasMarkedText(), range.location != NSNotFound,
              NSMaxRange(range) <= attributedString().length else { return false }
        var containsBlock = false
        if range.length > 0 {
            attributedString().enumerateAttribute(.originalBlockToken, in: range) { value, _, _ in
                if value != nil { containsBlock = true }
            }
        }
        guard !containsBlock else { NSSound.beep(); return false }
        let text = InternalNoteLinks.link(label, target: target)
        insertText(text, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + text.utf16.count, length: 0))
        return true
    }
    var sourceText: String { Self.source(from: attributedString()) }

    static func source(from attributed: NSAttributedString) -> String {
        let result = NSMutableString(string: attributed.string)
        var replacements: [(NSRange, String)] = []
        attributed.enumerateAttribute(.originalBlockToken, in: NSRange(location: 0, length: attributed.length)) { token, range, _ in
            if let token = token as? String { replacements.append((range, token)) }
        }
        for (range, token) in replacements.reversed() { result.replaceCharacters(in: range, with: token) }
        return result as String
    }
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.source(from: attributedString().attributedSubstring(from: range)), forType: .string)
    }
    override func paste(_ sender: Any?) {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { onFiles?(urls); return }
        if let data = NSPasteboard.general.data(forType: .png) { onImage?(data); return }
        if let tiff = NSPasteboard.general.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff), let png = image.representation(using: .png, properties: [:]) { onImage?(png); return }
        super.pasteAsPlainText(sender)
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { onFiles?(urls); return true }
        return super.performDragOperation(sender)
    }
    @objc func markdownBold(_ sender: Any?) { wrap("**", "**") }
    @objc func markdownItalic(_ sender: Any?) { wrap("*", "*") }
    @objc func markdownLink(_ sender: Any?) { wrap("[", "](https://)") }
    @objc func markdownCode(_ sender: Any?) { wrap("`", "`") }
    @objc func markdownTable(_ sender: Any?) { insertText("\n| 제목 | 내용 |\n| --- | --- |\n|  |  |\n", replacementRange: selectedRange()) }
    private func wrap(_ prefix: String, _ suffix: String) {
        guard isEditable, !hasMarkedText() else { return }
        let range = selectedRange()
        var containsBlock = false
        attributedString().enumerateAttribute(.originalBlockToken, in: range) { value, _, _ in if value != nil { containsBlock = true } }
        guard !containsBlock else { NSSound.beep(); return }
        let selection = Self.source(from: attributedString().attributedSubstring(from: range))
        insertText(prefix + selection + suffix, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + prefix.utf16.count, length: selection.utf16.count))
    }
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), selectedRange().length == 0 else { super.insertNewline(sender); return }
        let text = string as NSString
        let caret = selectedRange().location
        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        let before = text.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
        if let regex = try? NSRegularExpression(pattern: "^(\\s*)([-*+] |([0-9]+)\\. )(\\[[ xX]\\] )?"), let match = regex.firstMatch(in: before, range: NSRange(location: 0, length: before.utf16.count)) {
            let value = before as NSString
            var prefix = value.substring(with: match.range)
            if value.substring(from: match.range.length).trimmingCharacters(in: .whitespaces).isEmpty {
                insertText("", replacementRange: NSRange(location: lineRange.location, length: match.range.length))
                super.insertNewline(sender); return
            }
            if match.range(at: 3).location != NSNotFound, let number = Int(value.substring(with: match.range(at: 3))) {
                prefix = value.substring(with: match.range(at: 1)) + "\(number + 1). "
            } else { prefix = prefix.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]") }
            super.insertNewline(sender); insertText(prefix, replacementRange: selectedRange()); return
        }
        super.insertNewline(sender)
    }
}
