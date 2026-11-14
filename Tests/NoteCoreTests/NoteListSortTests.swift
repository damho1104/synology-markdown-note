import Foundation
import NoteCore
import Testing

@Suite struct NoteListSortTests {
    @Test func allFieldsAndDirectionsOrderVisibleNotes() {
        func summary(_ title: String, created: TimeInterval, modified: TimeInterval) -> NoteSummary {
            var note = NoteRecord(title: title, notebookID: "book")
            note.createdAt = Date(timeIntervalSince1970: created)
            note.modifiedAt = Date(timeIntervalSince1970: modified)
            return note.summary
        }
        let notes = [summary("가", created: 30, modified: 10),
                     summary("나", created: 10, modified: 30),
                     summary("다", created: 20, modified: 20)]
        let expectations: [(NoteSortField, NoteSortDirection, [String])] = [
            (.title, .ascending, ["가", "나", "다"]),
            (.title, .descending, ["다", "나", "가"]),
            (.createdAt, .ascending, ["나", "다", "가"]),
            (.createdAt, .descending, ["가", "다", "나"]),
            (.modifiedAt, .ascending, ["가", "다", "나"]),
            (.modifiedAt, .descending, ["나", "다", "가"])
        ]
        for (field, direction, expected) in expectations {
            #expect(NoteListSort(field: field, direction: direction).sorted(notes).map(\.title) == expected)
        }
    }

    @Test func missingCreationDateAndTiesHaveDeterministicOrder() throws {
        var first = NoteRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "같음")
        var second = NoteRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "같음")
        let date = Date(timeIntervalSince1970: 200)
        first.createdAt = nil; first.modifiedAt = date
        second.createdAt = nil; second.modifiedAt = date
        for field in NoteSortField.allCases {
            for direction in NoteSortDirection.allCases {
                #expect(NoteListSort(field: field, direction: direction).sorted([first.summary, second.summary]).map(\.id) == [second.id, first.id])
            }
        }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for data in [try encoder.encode(first), try encoder.encode(first.summary)] {
            var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            json.removeValue(forKey: "createdAt")
            let older = try JSONSerialization.data(withJSONObject: json)
            if json["markdown"] != nil {
                #expect(try decoder.decode(NoteRecord.self, from: older).createdAt == nil)
            } else {
                #expect(try decoder.decode(NoteSummary.self, from: older).createdAt == nil)
            }
        }
    }

    @Test func repositoryPreservesCreationDateAcrossEditsAndRemoteRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try NoteRepository(directory: directory)
        let original = try await repository.save(NoteRecord(title: "로컬"))
        var edit = original
        edit.title = "수정된 제목"
        let saved = try await repository.save(edit)
        #expect(saved.createdAt == original.createdAt)
        #expect(try await repository.listNotes().first?.createdAt == original.createdAt)

        var remote = NoteRecord(title: "서버", notebookID: "book")
        remote.remoteID = "remote-note"
        remote.createdAt = Date(timeIntervalSince1970: 100)
        remote.modifiedAt = Date(timeIntervalSince1970: 500)
        try await repository.observeRemote(remote)
        remote.createdAt = nil
        remote.modifiedAt = Date(timeIntervalSince1970: 600)
        try await repository.observeRemote(remote)
        #expect(try await repository.note(remoteID: "remote-note")?.createdAt == Date(timeIntervalSince1970: 100))
    }
}
