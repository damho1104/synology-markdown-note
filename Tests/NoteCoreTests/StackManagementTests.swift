import Foundation
import Testing
@testable import NoteCore
@testable import SynologyNote

@Suite struct StackManagementTests {
    @Test func oldNotebookJSONDecodesWithoutStackAndNewValuePersists() async throws {
        let old = try JSONDecoder().decode(Notebook.self, from: Data(#"{"id":"old","name":"기존 메모장"}"#.utf8))
        #expect(old.stack == "")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try NoteRepository(directory: root)
        try await first.setNotebooks([old, Notebook(id: "new", name: "테스트", stack: "업무")])
        let reopened = try NoteRepository(directory: root)
        let books = try await reopened.notebooks()
        #expect(books.first(where: { $0.id == "old" })?.stack == "")
        #expect(books.first(where: { $0.id == "new" })?.stack == "업무")
    }

    @Test func listingReadsStackAndMovingManyUsesOfficialNotebookSet() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        server.stackedBooks([("a", "A", ""), ("b", "B", "")])
        server.json([:]) { req in
            #expect(req["api"] == "SYNO.NoteStation.Notebook")
            #expect(req["version"] == "2" && req["method"] == "set")
            #expect(req["object_id"] == #"["a","b"]"#)
            #expect(req["stack"] == #""업무""#)
            #expect(req["commit_msg"] == #"{"device":"desktop"}"#)
        }
        server.stackedBooks([("a", "A", "업무"), ("b", "B", "업무")])
        let after = try await client.moveNotebooksToStack(ids: ["a", "b"], name: "업무")
        #expect(after.count == 2 && after.allSatisfy { $0.stack == "업무" })

        server.stackedBooks([("a", "A", "업무"), ("b", "B", "업무")])
        server.successOnly()
        server.stackedBooks([("a", "A", ""), ("b", "B", "업무")])
        let ungrouped = try await client.moveNotebooksToStack(ids: ["a"], name: "")
        #expect(ungrouped.first(where: { $0.id == "a" })?.stack == "")
        #expect(server.requests.filter { $0["method"] == "set" }.count == 2)
        server.assertConsumed()
    }

    @Test func renameAndDeleteUseInfoOwnerUIDAndKeepAllNotebooks() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        server.stackedBooks([("a", "A", "원래"), ("b", "B", "원래")])
        server.json(["uid": 42]) { req in
            #expect(req["api"] == "SYNO.NoteStation.Info" && req["method"] == "get")
            #expect(req["version"] == "2")
        }
        server.successOnly()
        server.stackedBooks([("a", "A", "변경"), ("b", "B", "변경")])
        let renamed = try await client.renameStack(from: "원래", to: "변경")
        #expect(renamed.count == 2 && renamed.allSatisfy { $0.stack == "변경" })
        let set = try #require(server.requests.first(where: { $0["api"] == "SYNO.NoteStation.Stack" }))
        #expect(set["method"] == "set" && set["stack_id"] == #""원래#42""# && set["name"] == #""변경""#)

        server.stackedBooks([("a", "A", "변경"), ("b", "B", "변경")])
        server.json(["uid": 42])
        server.successOnly()
        server.stackedBooks([("a", "A", ""), ("b", "B", "")])
        let deleted = try await client.deleteStack(name: "변경")
        #expect(deleted.map(\.id).sorted() == ["a", "b"])
        #expect(deleted.allSatisfy { $0.stack.isEmpty })
        let delete = try #require(server.requests.last(where: { $0["api"] == "SYNO.NoteStation.Stack" }))
        #expect(delete["method"] == "delete" && delete["version"] == "1" && delete["stack_id"] == #""변경#42""#)
        #expect(!server.requests.contains { $0["api"] == "SYNO.NoteStation.Notebook" && $0["method"] == "delete" })
        server.assertConsumed()
    }

    @Test func renameWaitsForDelayedListVisibilityWithoutRepeatingWrite() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        server.stackedBooks([("a", "A", "이전")])
        server.json(["uid": 42])
        server.successOnly()
        server.stackedBooks([("a", "A", "이전")])
        server.stackedBooks([("a", "A", "새이름")])

        let books = try await client.renameStack(from: "이전", to: "새이름")
        #expect(books.first?.stack == "새이름")
        #expect(server.requests.filter { $0["api"] == "SYNO.NoteStation.Stack" && $0["method"] == "set" }.count == 1)
        server.assertConsumed()
    }

    @Test func renameWithUnconfirmedReadbackReportsUncertainAndNeverRetriesWrite() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        server.stackedBooks([("a", "A", "이전")])
        server.json(["uid": 42])
        server.successOnly()
        for _ in 0..<6 { server.stackedBooks([("a", "A", "이전")]) }

        await #expect(throws: NoteStationError.stackWriteUncertain) {
            try await client.renameStack(from: "이전", to: "새이름")
        }
        #expect(server.requests.filter { $0["api"] == "SYNO.NoteStation.Stack" && $0["method"] == "set" }.count == 1)
        server.assertConsumed()
    }

    @Test func lostMoveResponseReadsBackWithoutDuplicateWrites() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        server.stackedBooks([("a", "A", "")]); server.lost(); server.stackedBooks([("a", "A", "업무")])
        #expect(try await client.moveNotebooksToStack(ids: ["a"], name: "업무").first?.stack == "업무")
        #expect(server.requests.filter { $0["method"] == "set" }.count == 1)
        server.assertConsumed()
    }

    @Test func uncertainMoveNeverPretendsCompletionOrAutomaticallyRetries() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        server.stackedBooks([("a", "A", "")]); server.lost(); server.stackedBooks([("a", "A", "")])
        await #expect(throws: NoteStationError.stackWriteUncertain) {
            try await client.moveNotebooksToStack(ids: ["a"], name: "업무")
        }
        #expect(server.requests.filter { $0["method"] == "set" }.count == 1)
        server.assertConsumed()
    }

    @Test func missingInfoUIDPreventsStackMutation() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        server.stackedBooks([("a", "A", "업무")]); server.json([:])
        await #expect(throws: NoteStationError.invalidResponse) {
            try await client.deleteStack(name: "업무")
        }
        #expect(!server.requests.contains { $0["api"] == "SYNO.NoteStation.Stack" })
        server.assertConsumed()
    }

    @Test func aNewStackCannotSilentlyMergeWithExistingStack() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        server.stackedBooks([("a", "A", ""), ("b", "B", "업무")])
        await #expect(throws: NoteStationError.invalidArgument("duplicate stack name")) {
            try await client.moveNotebooksToStack(ids: ["a"], name: "업무", creatingNew: true)
        }
        #expect(!server.requests.contains { $0["method"] == "set" })
        server.assertConsumed()
    }

    @Test func explicitAPIRejectionReturnsOriginalErrorWithoutRetrying() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        server.stackedBooks([("a", "A", "")])
        server.error(code: 9999)
        await #expect(throws: NoteStationError.api(code: 9999)) {
            try await client.moveNotebooksToStack(ids: ["a"], name: "업무")
        }
        #expect(server.requests.filter { $0["method"] == "set" }.count == 1)
        server.assertConsumed()
    }

    @MainActor @Test func storeStackMovementPersistsAndPreservesNoteData() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ConnectionProfile(server: "https://\(server.host)", username: "user")
        let store = try LibraryStore(root: root, profile: profile)
        store.client = client; store.isConnected = true
        try await store.repository.setNotebooks([Notebook(id: "a", name: "A"), Notebook(id: "b", name: "B")])
        let saved = try await store.repository.save(NoteRecord(title: "보존", notebookID: "a", markdown: "# 변경하면 안 됨"), enqueue: false)
        server.stackedBooks([("a", "A", ""), ("b", "B", "")])
        server.successOnly()
        server.stackedBooks([("a", "A", "기획"), ("b", "B", "")])
        try await store.moveNotebooksToStack(ids: ["a"], name: "기획", creatingNew: true)
        #expect(store.stackNames == ["기획"])
        #expect(store.filtered(.stack("기획")).map(\.title) == ["보존"])
        let reopened = try LibraryStore(root: root, profile: profile)
        try await reopened.reload()
        #expect(reopened.stackNames == ["기획"])
        #expect(try await reopened.repository.note(id: saved.id)?.markdown == "# 변경하면 안 됨")
        server.assertConsumed()
    }

    @MainActor @Test func creatingStackWaitsForAnActiveRefreshBeforeWriting() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://\(server.host)", username: "user"))
        store.client = client; store.isConnected = true; store.isRefreshing = true
        try await store.repository.setNotebooks([Notebook(id: "a", name: "A")])
        server.stackedBooks([("a", "A", "")]); server.successOnly(); server.stackedBooks([("a", "A", "업무")])

        let creation = Task { try await store.moveNotebooksToStack(ids: ["a"], name: "업무", creatingNew: true) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!server.requests.contains { $0["method"] == "set" })
        store.isRefreshing = false
        try await creation.value
        #expect(store.stackNames == ["업무"])
        #expect(server.requests.filter { $0["method"] == "set" }.count == 1)
        server.assertConsumed()
    }

    @MainActor @Test func creatingStackWaitsForAnActiveUploadBeforeWriting() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://\(server.host)", username: "user"))
        store.client = client; store.isConnected = true; store.isPushing = true
        try await store.repository.setNotebooks([Notebook(id: "a", name: "A")])
        server.stackedBooks([("a", "A", "")]); server.successOnly(); server.stackedBooks([("a", "A", "업무")])

        let creation = Task { try await store.moveNotebooksToStack(ids: ["a"], name: "업무", creatingNew: true) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!server.requests.contains { $0["method"] == "set" })
        store.isPushing = false
        try await creation.value
        #expect(store.stackNames == ["업무"])
        #expect(server.requests.filter { $0["method"] == "set" }.count == 1)
        server.assertConsumed()
    }

    @MainActor @Test func cancelledStackCreationReleasesReservationWithoutWriting() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://\(server.host)", username: "user"))
        store.client = client; store.isConnected = true; store.isRefreshing = true
        let creation = Task { try await store.moveNotebooksToStack(ids: ["a"], name: "업무", creatingNew: true) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.isManagingStacks)
        creation.cancel()
        await #expect(throws: CancellationError.self) { try await creation.value }
        #expect(!store.isManagingStacks)
        #expect(!server.requests.contains { $0["method"] == "set" })
        server.assertConsumed()
    }

    @MainActor @Test func connectionChangeWhileWaitingPreventsStackWrite() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://\(server.host)", username: "user"))
        store.client = client; store.isConnected = true; store.isPushing = true
        let creation = Task { try await store.moveNotebooksToStack(ids: ["a"], name: "업무", creatingNew: true) }
        try await Task.sleep(for: .milliseconds(100))
        store.connectionGeneration += 1
        await #expect(throws: NoteStationError.connectionChanged) { try await creation.value }
        #expect(!store.isManagingStacks)
        #expect(!server.requests.contains { $0["method"] == "set" })
        server.assertConsumed()
    }

    @MainActor @Test func concurrentStackCreationCannotDuplicateNASWrite() async throws {
        let server = ManagementNAS(); defer { server.close() }
        let client = try await server.connectedClient()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://\(server.host)", username: "user"))
        store.client = client; store.isConnected = true; store.isRefreshing = true
        try await store.repository.setNotebooks([Notebook(id: "a", name: "A")])
        server.stackedBooks([("a", "A", "")]); server.successOnly(); server.stackedBooks([("a", "A", "업무")])
        let first = Task { try await store.moveNotebooksToStack(ids: ["a"], name: "업무", creatingNew: true) }
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: NoteStationError.writeContractUnvalidated) {
            try await store.moveNotebooksToStack(ids: ["a"], name: "업무", creatingNew: true)
        }
        store.isRefreshing = false
        try await first.value
        #expect(server.requests.filter { $0["method"] == "set" }.count == 1)
        server.assertConsumed()
    }

    @MainActor @Test func stackFilterUsesCurrentAccountNotebookMembership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://example.invalid", username: "alpha"))
        let b = try LibraryStore(root: root, profile: ConnectionProfile(server: "https://example.invalid", username: "beta"))
        try await a.repository.setNotebooks([Notebook(id: "a", name: "A", stack: "업무"), Notebook(id: "b", name: "B")])
        _ = try await a.repository.save(NoteRecord(title: "A", notebookID: "a", markdown: "hello"), enqueue: false)
        _ = try await a.repository.save(NoteRecord(title: "B", notebookID: "b", markdown: "hello"), enqueue: false)
        try await a.reload()
        #expect(a.stackNames == ["업무"] && a.filtered(.stack("업무")).map(\.title) == ["A"])
        try await b.reload()
        #expect(b.stackNames.isEmpty && b.filtered(.stack("업무")).isEmpty)
    }
}
