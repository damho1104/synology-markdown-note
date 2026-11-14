import Foundation
import NoteCore

let documentID = UUID(uuidString: "12345678-1234-4321-ABCD-123456789ABC")!
let operationID = UUID(uuidString: "87654321-4321-4321-ABCD-ABCDEF123456")!
let assetID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
let markdown = "---\ntitle: 한글 🐱\n---\r\n# 제목 & 따옴표\r\n본문  끝"
let cases: [(String, SourceEnvelope)] = [
    ("v1", SourceEnvelope(documentID: documentID, markdown: markdown, blocks: [], html: "<h1>제목</h1>\n")),
    ("v2", SourceEnvelope(documentID: documentID, markdown: markdown, blocks: [], html: "<h1>제목</h1>\n", operationID: operationID, attachmentBindings: [assetID.uuidString: "nas-file-1"])),
    ("v3", SourceEnvelope(documentID: documentID, markdown: "$x$\n", blocks: [], html: "<p>x</p>\n", operationID: operationID,
                          attachmentBindings: [assetID.uuidString: "nas-file-1"],
                          mathAttachments: [assetID.uuidString: MathAttachmentMetadata(key: String(repeating: "a", count: 64), width: 20, height: 10.5)])),
    ("blocks", SourceEnvelope(documentID: documentID, markdown: "앞\n\n:::synology-block keep :::\n", blocks: [PreservedBlock(id: "keep", html: "<div lang=\"ko\">보존</div>", label: "원본")], html: "<p>앞</p>\n<div lang=\"ko\">보존</div>\n"))
]
let samples = [
    "# 제목 **강조**\n\n안녕 & <tag>\n",
    "- 첫째\n- 둘째\n  - 중첩\n",
    "- [x] 완료\n- [ ] 대기\n",
    "| 이름 | 값 |\n| :--- | ---: |\n| 한글 | ~~취소~~ |\n",
    "3. 항목\n4. 다음\n\n> 인용 *글*\n",
    "```swift\nlet a = \"한글\"\n```\n",
    "[연결](https://example.com/?a=1&b=2 \"제목\")\n",
    "일반\n다음  \n줄\n"
]
let values: [String: Any] = [
    "envelopes": Dictionary(uniqueKeysWithValues: cases.map {
        ($0.0, ["document_id": documentID.uuidString, "markdown": $0.1.markdown,
               "html": $0.0 == "v3" ? "<p>x</p>\n" : $0.0 == "blocks" ? "<p>앞</p>\n<div lang=\"ko\">보존</div>\n" : "<h1>제목</h1>\n",
               "encoded_base64": $0.1.encoded().base64EncodedString()])
    }),
    "render": samples.map { ["markdown": $0, "html": MarkdownPipeline.render($0)] },
    "render_blocks": [
        ["markdown": "Intro\n\n:::synology-block original :::\n", "blocks": [
            ["id": "original", "html": "<div lang=\"ko\">원문</div>", "label": "원본"]
        ], "html": MarkdownPipeline.render("Intro\n\n:::synology-block original :::\n", blocks: [
            PreservedBlock(id: "original", html: "<div lang=\"ko\">원문</div>", label: "원본")
        ])]
    ]
]
let json = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
let target = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "contracts/source-envelope/fixtures.json")
try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
try json.write(to: target, options: .atomic)
print("Generated Swift contract fixtures: \(target.path)")
