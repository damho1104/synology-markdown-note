import AppKit
import SwiftUI
import WebKit
import Testing
@testable import NoteCore
@testable import SynologyNote

@Suite(.serialized) @MainActor struct OriginalHTMLEditorTests {
    @Test func unchangedHTMLIsByteExactAndSelectionDoesNotEdit() async throws {
        let source = "<DIV style='font-family: Georgia; color: #123456'>한글 &amp; 원본</DIV>\n<!--keep-->"
        let editor = try await OriginalEditorHarness(source)
        defer { editor.close() }
        #expect(try await editor.html() == source)
        try await editor.run("const r = document.createRange(); r.selectNodeContents(document.querySelector('#original-editor').firstChild); getSelection().removeAllRanges(); getSelection().addRange(r); return true")
        #expect(try await editor.html() == source)
        #expect(editor.edits.isEmpty)
    }

    @Test func editsKoreanAndFormatsWithoutMarkdownConversion() async throws {
        let editor = try await OriginalEditorHarness("<h2 style='font-family:Georgia'>제목</h2><p>안녕</p><ul><li>목록</li></ul>")
        defer { editor.close() }
        try await editor.select("p")
        try await editor.command("insertText", "한국어 입력")
        try await editor.select("p")
        try await editor.command("bold")
        let html = try await editor.html()
        #expect(html.contains("한국어 입력"))
        #expect(html.contains("<b>") || html.contains("font-weight: bold"))
        #expect(html.contains("<h2") && html.contains("Georgia") && html.contains("<ul>"))
        #expect(!html.contains("original-editor"))
        #expect(!html.contains("data-sne-"))
        try await editor.waitForEdits()
        #expect(editor.value == html)
    }

    @Test func tableControlsCreateAndDeleteRowsAndColumns() async throws {
        let editor = try await OriginalEditorHarness("<p>표</p>")
        defer { editor.close() }
        try await editor.select("p", collapsed: true)
        try await editor.command("table", "2x2")
        #expect(try await editor.run("return document.querySelectorAll('#original-editor td').length") as? Int == 4)
        try await editor.select("td", collapsed: true)
        try await editor.command("rowAfter")
        try await editor.command("columnAfter")
        #expect(try await editor.run("return document.querySelectorAll('#original-editor tr').length") as? Int == 3)
        #expect(try await editor.run("return document.querySelectorAll('#original-editor td').length") as? Int == 9)
        try await editor.command("deleteColumn")
        try await editor.command("deleteRow")
        #expect(try await editor.run("return document.querySelectorAll('#original-editor td').length") as? Int == 4)
    }

    @Test func attachmentPreviewUsesVerifiedStoreAndExportsOriginalReferences() async throws {
        let editor = try await OriginalEditorHarness("<p>본문</p>")
        defer { editor.close() }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        var attachment = try await editor.store.importData(png, name: "pixel.png")
        attachment.remoteID = "remote-picture"
        let source = "<p>본문</p><img ref='remote-picture' src='/webman/image?file_id=remote-picture' style='width:20px'>"
        editor.reload(source, attachments: [attachment])
        try await editor.waitUntilReady()
        #expect(try await editor.run("return document.querySelector('#original-editor img').getAttribute('src')") as? String == attachment.reference)
        for _ in 0..<100 {
            if try await editor.run("return document.querySelector('#original-editor img').naturalWidth") as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await editor.run("return document.querySelector('#original-editor img').naturalWidth") as? Int == 1)
        try await editor.select("p")
        try await editor.command("insertText", "수정")
        let html = try await editor.html()
        #expect(html.contains("/webman/image?file_id=remote-picture"))
        #expect(html.contains("ref=\"remote-picture\""))
        #expect(!html.contains("attachment://"))
        #expect(!html.contains("data-sne-"))
    }

    @Test func refOnlyNASImageDisplaysVerifiedDataAndExportsWithoutSrc() async throws {
        let editor = try await OriginalEditorHarness("<p>원본</p>")
        defer { editor.close() }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        var attachment = try await editor.store.importData(png, name: "nas.png")
        attachment.remoteReference = "nas-original-reference"
        let source = "<p style='font-family:Georgia'>이전 &amp; 원본</p><img ref='nas-original-reference' alt='그림'>"
        editor.reload(source, attachments: [attachment])
        try await editor.waitUntilReady()
        #expect(try await editor.run("return document.querySelector('#original-editor img').getAttribute('src')") as? String == attachment.reference)
        for _ in 0..<100 {
            if try await editor.run("return document.querySelector('#original-editor img').naturalWidth") as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await editor.run("return document.querySelector('#original-editor img').naturalWidth") as? Int == 1)
        #expect(try await editor.html() == source)
        try await editor.select("p")
        try await editor.command("insertText", "수정")
        let exported = try await editor.html()
        #expect(exported.contains("ref=\"nas-original-reference\""))
        #expect(!exported.contains("src=") && !exported.contains("attachment://"))
        try await editor.waitForEdits()
        editor.undo.undo()
        try await editor.waitUntilReady()
        #expect(editor.value == source)
        #expect(try await editor.html() == source)
    }

    @Test func hostileScriptsRemoteImagesAndOpaqueWidgetsStayInert() async throws {
        let source = "<p onclick='window.hostile=1'>안전</p><script>window.hostile=2;fetch('https://example.invalid')</script><iframe src='https://example.invalid'></iframe><img src='https://example.invalid/tracker.png' onerror='window.hostile=3'><synology-widget data-value='x'>보존</synology-widget>"
        let editor = try await OriginalEditorHarness(source)
        defer { editor.close() }
        #expect(try await editor.run("return typeof window.hostile") as? String == "undefined")
        #expect(try await editor.run("return document.querySelectorAll('#original-editor script, #original-editor iframe, #original-editor synology-widget').length") as? Int == 0)
        #expect(try await editor.run("return document.querySelector('#original-editor img').hasAttribute('src')") as? Bool == false)
        try await editor.select("p")
        try await editor.command("insertText", "편집")
        let html = try await editor.html()
        #expect(html.contains("<synology-widget"))
        #expect(html.contains("data-value=\"x\""))
        #expect(html.contains("https://example.invalid/tracker.png"))
        #expect(!html.contains("data-sne-"))
        #expect(try await editor.run("return performance.getEntriesByType('resource').filter(x => /^https?:/.test(x.name)).length") as? Int == 0)
        try await editor.run("document.querySelector('#original-editor').insertAdjacentHTML('beforeend','<a href=\"https://example.invalid\">외부</a>'); document.querySelector('#original-editor a').click(); return true")
        #expect(editor.web.url?.scheme == "about")
    }

    @Test func sessionUndoRedoAndStaleLifecycleCallbacks() async throws {
        let editor = try await OriginalEditorHarness("<p>이전</p>")
        defer { editor.close() }
        try await editor.select("p")
        try await editor.command("insertText", "다음")
        try await editor.waitForEdits()
        #expect(editor.undo.canUndo)
        editor.undo.undo()
        try await editor.waitUntilReady()
        #expect(editor.value == "<p>이전</p>")
        #expect(try await editor.html() == "<p>이전</p>")
        editor.undo.redo()
        try await editor.waitUntilReady()
        #expect(editor.value.contains("다음"))
        let staleRevision = editor.coordinator.revision
        editor.reload("<p>새 노트</p>")
        try await editor.waitUntilReady()
        editor.coordinator.receive(["revision": staleRevision, "html": "<p>오래된 수정</p>"])
        #expect(editor.value == "<p>새 노트</p>")
        #expect(!editor.undo.canUndo)
    }

    @Test func classStylesAndFullDocumentEnvelopeSurviveEditing() async throws {
        let source = "<!DOCTYPE html><html lang='ko'><head><style>p { color: rgb(12, 34, 56); font-family: Georgia } body { font-size:19px } button { display:none } @import url(https://example.invalid/style.css);</style><title>노트</title></head><body style='background-color:rgb(240, 240, 240)'><p>본문</p></body></html>"
        let editor = try await OriginalEditorHarness(source)
        defer { editor.close() }
        #expect(try await editor.run("return getComputedStyle(document.querySelector('#original-editor p')).color") as? String == "rgb(12, 34, 56)")
        #expect(try await editor.run("return getComputedStyle(document.querySelector('#original-editor p')).fontSize") as? String == "19px")
        #expect(try await editor.run("return getComputedStyle(document.querySelector('#original-toolbar button')).display") as? String != "none")
        #expect(try await editor.html() == source)
        try await editor.select("p")
        try await editor.command("insertText", "수정")
        let html = try await editor.html()
        #expect(html.contains("<!DOCTYPE html>") && html.contains("<html lang=\"ko\">") && html.contains("<title>노트</title>"))
        #expect(html.contains("font-family: Georgia") && html.contains("background-color:rgb(240, 240, 240)"))
        #expect(!html.contains("original-editor"))
        #expect(try await editor.run("return performance.getEntriesByType('resource').filter(x=>/^https?:/.test(x.name)).length") as? Int == 0)
    }

    @Test func changingFontSizeDoesNotRestyleUnselectedOriginalFont() async throws {
        let editor = try await OriginalEditorHarness("<p><font size='7'>유지</font></p><p id='change'>수정</p>")
        defer { editor.close() }
        try await editor.select("#change")
        try await editor.command("fontSize", "18")
        #expect(try await editor.run("return document.querySelector('#original-editor p:first-child font').getAttribute('size')") as? String == "7")
        #expect(try await editor.run("return getComputedStyle(document.querySelector('#change').firstElementChild).fontSize") as? String == "18px")
    }

    @Test func pasteKeepsRichTextButCannotInsertActiveCodeOrPreviewArtifacts() async throws {
        let editor = try await OriginalEditorHarness("<p>붙여넣기</p>")
        defer { editor.close() }
        try await editor.select("p")
        try await editor.run("return window.originalEditor.pasteHTML('<b>한글</b><script>window.pasteAttack=1</script><img src=\"https://example.invalid/image\" onerror=\"window.pasteAttack=2\">')")
        let html = try await editor.html()
        #expect(html.contains("<b>한글</b>"))
        #expect(!html.contains("script") && !html.contains("onerror") && !html.contains("example.invalid"))
        #expect(!html.contains("원본 보존") && !html.contains("data-sne-"))
        #expect(try await editor.run("return typeof window.pasteAttack") as? String == "undefined")
    }

    @Test func nativeClipboardCallbacksRespectReadOnlyAndDetach() async throws {
        let editor = try await OriginalEditorHarness("<p>파일</p>")
        defer { editor.close() }
        let file = editor.directory.appendingPathComponent("sample.txt")
        try Data("test".utf8).write(to: file)
        #expect(editor.web.isEditorEditable)
        #expect(editor.web.pasteAttachments(from: TestEditorClipboard(files: [file])))
        #expect(editor.files == [file])
        let bytes = Data([1, 2, 3])
        let imageClipboard = TestEditorClipboard(png: bytes)
        #expect(editor.web.pasteAttachments(from: imageClipboard))
        #expect(editor.images == [bytes])
        editor.reload(editor.value, editable: false)
        try await editor.waitUntilReady()
        #expect(!editor.web.pasteAttachments(from: imageClipboard))
        #expect(editor.images.count == 1)
        editor.coordinator.detach()
        editor.web.pasteAttachments(from: imageClipboard)
        #expect(editor.images.count == 1)
    }

    @Test func corruptedAttachmentNeverReachesWebKitImageDecoder() async throws {
        let editor = try await OriginalEditorHarness("<p>파일</p>")
        defer { editor.close() }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        let attachment = try await editor.store.importData(png, name: "corrupt.png")
        let path = await editor.store.url(for: attachment)
        try Data("corrupt".utf8).write(to: path)
        editor.reload("<img src='\(attachment.reference)'>", attachments: [attachment])
        try await editor.waitUntilReady()
        for _ in 0..<100 {
            if try await editor.run("return document.querySelector('#original-editor img').complete") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await editor.run("return document.querySelector('#original-editor img').naturalWidth") as? Int == 0)
    }

    @Test func keyboardUndoAndToolbarFormattingRetainTheSelectedText() async throws {
        let editor = try await OriginalEditorHarness("<p id='one'>첫 문단</p><p id='two'>둘째 문단</p>")
        defer { editor.close() }
        try await editor.select("#two")
        try await editor.run("const b=document.querySelector('#original-toolbar button[aria-label=굵게]');b.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}));b.click();return true")
        let formatted = try await editor.html()
        #expect(formatted.contains("<p id=\"one\">첫 문단</p>"))
        #expect(formatted.contains("<b>둘째 문단</b>") || formatted.contains("font-weight: bold"))
        try await editor.waitForEdits()
        #expect(editor.web.undoManager?.canUndo == true)
        try await editor.run("document.querySelector('#original-editor').dispatchEvent(new KeyboardEvent('keydown',{key:'z',metaKey:true,bubbles:true,cancelable:true}));return true")
        try await editor.waitUntilReady()
        #expect(editor.value == "<p id='one'>첫 문단</p><p id='two'>둘째 문단</p>")
        editor.web.undoManager?.redo()
        try await editor.waitUntilReady()
        #expect(editor.value == formatted)
    }

    @Test func copyAndCutRestoreAttachmentReferencesWithoutPlaceholders() async throws {
        let editor = try await OriginalEditorHarness("<p>원본</p>")
        defer { editor.close() }
        var attachment = try await editor.store.importData(Data([1]), name: "image.png")
        attachment.remoteID = "asset"
        editor.reload("<p><img ref='asset' src='/remote?file_id=asset'><synology-widget>원본</synology-widget></p>", attachments: [attachment])
        try await editor.waitUntilReady()
        try await editor.select("p")
        let copy = try await editor.run("const d=new DataTransfer();document.querySelector('#original-editor').dispatchEvent(new ClipboardEvent('copy',{clipboardData:d,bubbles:true,cancelable:true}));return d.getData('text/html')") as? String
        #expect(copy?.contains("/remote?file_id=asset") == true)
        #expect(copy?.contains("<synology-widget>") == true)
        #expect(copy?.contains("attachment://") == false)
        let cut = try await editor.run("const d=new DataTransfer();document.querySelector('#original-editor').dispatchEvent(new ClipboardEvent('cut',{clipboardData:d,bubbles:true,cancelable:true}));return d.getData('text/html')") as? String
        #expect(cut?.contains("/remote?file_id=asset") == true)
        #expect(cut?.contains("data-sne-") == false)
        #expect(!(try await editor.html()).contains("<img"))
    }

    @Test func attachmentRefreshDoesNotDestroyKoreanComposition() async throws {
        let editor = try await OriginalEditorHarness("<p>처음</p>")
        defer { editor.close() }
        try await editor.run("const r=document.querySelector('#original-editor');r.dispatchEvent(new CompositionEvent('compositionstart'));r.querySelector('p').textContent='한';return true")
        try await Task.sleep(for: .milliseconds(30))
        let asset = try await editor.store.importData(Data([1]), name: "pending.png")
        editor.assets = [asset]
        editor.coordinator.update(editor.parent)
        #expect(try await editor.run("return document.querySelector('#original-editor p').textContent") as? String == "한")
        try await editor.run("const r=document.querySelector('#original-editor');r.querySelector('p').textContent='한글';r.dispatchEvent(new CompositionEvent('compositionend'));return true")
        try await editor.waitForEdits()
        #expect(editor.value == "<p>한글</p>")
    }

    @Test func checkboxesListsLinksAndPageWorldIsolation() async throws {
        let editor = try await OriginalEditorHarness("<p>작업</p>")
        defer { editor.close() }
        try await editor.select("p")
        try await editor.command("checklist")
        try await editor.run("document.querySelector('#original-editor input[type=checkbox]').click();return true")
        #expect((try await editor.html()).contains("checked"))
        try await editor.select("li")
        try await editor.command("link", "https://example.invalid/note")
        #expect((try await editor.html()).contains("https://example.invalid/note"))
        #expect(try await editor.web.callAsyncJavaScript("return typeof window.originalEditor", arguments: [:], in: nil, contentWorld: .page) as? String == "undefined")
        #expect(!editor.web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    @Test func largeOriginalStyleSheetsAreScopedAndNeverSerializedAsEditorCSS() async throws {
        let css = (0..<1500).map { ".keep\($0) { margin-left: \($0 % 10)px }" }.joined() + ".target { font-family:Georgia;color:rgb(21, 43, 65) } button { display:none }"
        let source = "<style>\(css)</style><p class='target'>큰 원본</p>"
        let editor = try await OriginalEditorHarness(source)
        defer { editor.close() }
        #expect(try await editor.run("return getComputedStyle(document.querySelector('#original-editor p')).color") as? String == "rgb(21, 43, 65)")
        #expect(try await editor.run("return getComputedStyle(document.querySelector('#original-toolbar button')).display") as? String != "none")
        #expect(try await editor.html() == source)
        try await editor.select("p")
        try await editor.command("insertText", "수정한 큰 원본")
        let html = try await editor.html()
        #expect(html.contains(css))
        #expect(!html.contains("#original-editor"))
        #expect(!html.contains("data-sne-"))
    }

    @Test func hostileFullDocumentCannotExecuteInPageWorldOrRequestRemoteResources() async throws {
        let editor = try await OriginalEditorHarness("<!DOCTYPE html><html><head><script>window.fullAttack=1</script><link rel='stylesheet' href='https://example.invalid/a.css'></head><body onload='window.fullAttack=2'><img src='https://example.invalid/pixel' onerror='window.fullAttack=3'><iframe src='https://example.invalid/frame'></iframe><p>안전</p></body></html>")
        defer { editor.close() }
        #expect(try await editor.web.callAsyncJavaScript("return typeof window.fullAttack", arguments: [:], in: nil, contentWorld: .page) as? String == "undefined")
        #expect(try await editor.run("return document.querySelectorAll('#original-editor script,#original-editor iframe').length") as? Int == 0)
        #expect(try await editor.run("return performance.getEntriesByType('resource').filter(x=>/^https?:/.test(x.name)).length") as? Int == 0)
        try await editor.select("p")
        try await editor.command("insertText", "편집")
        let exported = try await editor.html()
        #expect(!exported.contains("<script") && !exported.contains("onload=") && !exported.contains("onerror="))
        #expect(exported.contains("<iframe") && exported.contains("https://example.invalid/pixel"))
        #expect(try await editor.web.callAsyncJavaScript("return typeof window.fullAttack", arguments: [:], in: nil, contentWorld: .page) as? String == "undefined")
    }

    @Test func opaqueWidgetsSurviveCutPasteRoundTrip() async throws {
        let editor = try await OriginalEditorHarness("<p><synology-widget data-value='keep'>원본</synology-widget></p>")
        defer { editor.close() }
        try await editor.select("p")
        let cut = try #require(try await editor.run("const d=new DataTransfer();document.querySelector('#original-editor').dispatchEvent(new ClipboardEvent('cut',{clipboardData:d,bubbles:true,cancelable:true}));return d.getData('text/html')") as? String)
        _ = try await editor.web.callAsyncJavaScript("return window.originalEditor.pasteHTML(html)", arguments: ["html": cut], in: nil, contentWorld: OriginalEditorRuntime.world)
        let html = try await editor.html()
        #expect(html.contains("<synology-widget") && html.contains("data-value=\"keep\"") && html.contains("원본"))
        #expect(!html.contains("원본 보존") && !html.contains("data-sne-"))
    }

    @Test func nativeUndoDuringCompositionDoesNotReplaceMarkedDOM() async throws {
        let editor = try await OriginalEditorHarness("<p>이전</p>")
        defer { editor.close() }
        try await editor.select("p")
        try await editor.command("insertText", "다음")
        try await editor.waitForEdits()
        try await editor.run("const r=document.querySelector('#original-editor');r.dispatchEvent(new CompositionEvent('compositionstart'));r.querySelector('p').textContent='한';return true")
        try await Task.sleep(for: .milliseconds(30))
        editor.web.undoManager?.undo()
        #expect(try await editor.run("return document.querySelector('#original-editor p').textContent") as? String == "한")
        // The app's toolbar calls the session manager directly, bypassing responders.
        editor.undo.undo()
        #expect(try await editor.run("return document.querySelector('#original-editor p').textContent") as? String == "한")
        try await editor.run("document.querySelector('#original-editor').dispatchEvent(new CompositionEvent('compositionend'));return true")
        try await editor.waitUntilReady()
        #expect(editor.value == "<p>이전</p>")
        #expect(editor.undo.canRedo)
    }

    @Test func attachmentRefreshCannotDiscardInputMessageAlreadyInFlight() async throws {
        let editor = try await OriginalEditorHarness("<p>이전</p>")
        defer { editor.close() }
        let previousRevision = editor.coordinator.revision
        // Change DOM without sending input yet, reproducing native bridge delivery delay.
        try await editor.run("document.querySelector('#original-editor p').textContent='방금 입력';return true")
        editor.assets = [try await editor.store.importData(Data([1]), name: "new.png")]
        editor.coordinator.update(editor.parent)
        editor.coordinator.receive(["revision": previousRevision, "html": "<p>방금 입력</p>"])
        #expect(editor.value == "<p>방금 입력</p>")
        #expect(try await editor.html() == "<p>방금 입력</p>")
    }

    @Test func raggedTableColumnOperationIsAtomicAndLeavesOriginalUntouched() async throws {
        let source = "<table><tbody><tr><td>A</td><td>B</td></tr><tr><td>C</td></tr></tbody></table>"
        let editor = try await OriginalEditorHarness(source)
        defer { editor.close() }
        try await editor.select("tr:first-child td:nth-child(2)", collapsed: true)
        try await editor.command("columnAfter")
        #expect(try await editor.html() == source)
        #expect(editor.edits.isEmpty)
    }

    @Test func compositionCommitsOnceAndReadOnlyRejectsCommands() async throws {
        let editor = try await OriginalEditorHarness("<p>처음</p>")
        defer { editor.close() }
        try await editor.run("const root=document.querySelector('#original-editor'); root.dispatchEvent(new CompositionEvent('compositionstart')); root.querySelector('p').textContent='한'; root.dispatchEvent(new InputEvent('input',{bubbles:true,isComposing:true})); return true")
        try await Task.sleep(for: .milliseconds(60))
        #expect(editor.edits.isEmpty)
        try await editor.run("const root=document.querySelector('#original-editor'); root.querySelector('p').textContent='한글'; root.dispatchEvent(new CompositionEvent('compositionend')); return true")
        try await editor.waitForEdits()
        #expect(editor.value == "<p>한글</p>")
        editor.reload(editor.value, editable: false)
        try await editor.waitUntilReady()
        try await editor.select("p")
        try await editor.command("insertText", "금지")
        #expect(try await editor.html() == "<p>한글</p>")
    }
}

@MainActor private final class OriginalEditorHarness {
    var value: String
    var edits: [String] = []
    let store: AttachmentStore
    let undo = UndoManager()
    var coordinator: OriginalHTMLEditor.Coordinator!
    var web: OriginalEditorWebView!
    var window: NSWindow!
    var assets: [NoteAttachment] = []
    var editable = true
    var files: [URL] = []
    var images: [Data] = []
    let directory: URL

    init(_ source: String) async throws {
        value = source
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try AttachmentStore(directory: directory)
        undo.groupsByEvent = false
        coordinator = OriginalHTMLEditor.Coordinator(parent)
        web = coordinator.makeWebView()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        coordinator.update(parent)
        try await waitUntilReady()
    }
    var parent: OriginalHTMLEditor {
        OriginalHTMLEditor(html: Binding(get: { self.value }, set: { self.value = $0; self.edits.append($0) }), attachments: assets, assetStore: store, isEditable: editable, undoManager: undo, onFiles: { self.files += $0 }, onImage: { self.images.append($0) })
    }
    func close() {
        coordinator.detach()
        window.contentView = nil
        web = nil
        window.orderOut(nil)
        window = nil
        coordinator = nil
        try? FileManager.default.removeItem(at: directory)
    }
    func reload(_ source: String, attachments: [NoteAttachment] = [], editable: Bool = true) {
        value = source; assets = attachments; self.editable = editable
        coordinator.update(parent)
    }
    func waitUntilReady() async throws {
        for _ in 0..<200 {
            if let error = coordinator.loadingError { throw error }
            if coordinator.isReady { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw OriginalEditorTestError.timeout
    }
    @discardableResult func run(_ body: String) async throws -> Any? {
        try await web.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: OriginalEditorRuntime.world)
    }
    func html() async throws -> String { try #require(try await run("return window.originalEditor.getHTML()") as? String) }
    func command(_ name: String, _ value: String = "") async throws {
        _ = try await web.callAsyncJavaScript("return window.originalEditor.command(name,value)", arguments: ["name": name, "value": value], in: nil, contentWorld: OriginalEditorRuntime.world)
    }
    func select(_ selector: String, collapsed: Bool = false) async throws {
        _ = try await web.callAsyncJavaScript("const n=document.querySelector('#original-editor '+selector); const r=document.createRange(); r.selectNodeContents(n); if(collapsed)r.collapse(false); getSelection().removeAllRanges();getSelection().addRange(r); document.querySelector('#original-editor').focus(); return true", arguments: ["selector": selector, "collapsed": collapsed], in: nil, contentWorld: OriginalEditorRuntime.world)
    }
    func waitForEdits() async throws {
        for _ in 0..<100 {
            if !edits.isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw OriginalEditorTestError.timeout
    }
}
private enum OriginalEditorTestError: Error { case timeout }

@MainActor private struct TestEditorClipboard: OriginalEditorAttachmentClipboard {
    var files: [URL] = []
    var png: Data? = nil

    func attachmentFileURLs() -> [URL] { files }
    func attachmentData(forType type: NSPasteboard.PasteboardType) -> Data? {
        type == .png ? png : nil
    }
}
