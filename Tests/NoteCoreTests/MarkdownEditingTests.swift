import Foundation
import Testing
@testable import NoteCore

@Suite struct MarkdownEditingTests {
    @Test func toggleTaskKeepsKoreanAndLineEndings() {
        let source = "# 한글\r\n\r\n- [ ] 첫 작업\r\n- [x] 다음 작업\r\n"
        let changed = MarkdownEditing.toggleTask(source, line: 3)
        #expect(changed == "# 한글\r\n\r\n- [x] 첫 작업\r\n- [x] 다음 작업\r\n")
        #expect(MarkdownEditing.toggleTask(changed, line: 3) == source)
    }
    @Test func previewOnlyDecoratesKnownTaskInputs() {
        let html = MarkdownPipeline.render("- [ ] 첫 작업\n\n```\n- [ ] 예제\n```\n")
        let preview = MarkdownEditing.interactivePreview(html)
        #expect(preview.contains("note-task://3") == false)
        #expect(preview.contains("note-task://1"))
        #expect(preview.contains("예제"))
        #expect(!preview.contains("javascript:"))
    }
}
