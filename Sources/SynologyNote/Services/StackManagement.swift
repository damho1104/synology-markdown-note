import AppKit
import Foundation
import NoteCore

extension LibraryStore {
    /// Reserve the stack operation before waiting, so another periodic upload
    /// cannot start between the idle check and the NAS write.
    private func waitForStackWriteTurn(client expectedClient: NoteStationClient,
                                       account: Int, connection: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while isRefreshing || isPushing {
            try Task.checkCancellation()
            guard account == accountGeneration, connection == connectionGeneration,
                  self.client === expectedClient, isConnected else { throw NoteStationError.connectionChanged }
            guard ContinuousClock.now < deadline else { throw NoteStationError.validationInProgress }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard account == accountGeneration, connection == connectionGeneration,
              self.client === expectedClient, isConnected else { throw NoteStationError.connectionChanged }
    }

    /// NAS is authoritative. Re-read the current account's local cache before
    /// updating it, so other notebook metadata changes survive the operation.
    private func installStackSnapshot(_ remote: [RemoteNotebook], client: NoteStationClient,
                                      account: Int, connection: Int, repo: NoteRepository) async throws {
        guard account == accountGeneration, connection == connectionGeneration, self.client === client else {
            throw NoteStationError.connectionChanged
        }
        var books = try await repo.notebooks()
        guard account == accountGeneration, connection == connectionGeneration, self.client === client else {
            throw NoteStationError.connectionChanged
        }
        let updated = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        for index in books.indices {
            if let row = updated[books[index].id] {
                books[index].name = row.name
                books[index].stack = row.stack
            }
        }
        for row in remote where !books.contains(where: { $0.id == row.id }) {
            books.append(Notebook(id: row.id, name: row.name, stack: row.stack))
        }
        try await repo.setNotebooks(books)
        guard account == accountGeneration, connection == connectionGeneration, self.client === client else {
            throw NoteStationError.connectionChanged
        }
        try await reload()
    }

    func moveNotebooksToStack(ids: [String], name: String, creatingNew: Bool = false) async throws {
        guard let client, canManageNASNotebooks, !isManagingStacks else {
            throw NoteStationError.writeContractUnvalidated
        }
        isManagingStacks = true
        defer { isManagingStacks = false; scheduleUpload() }
        let account = accountGeneration, connection = connectionGeneration, repo = repository
        let operation = creatingNew ? "create" : "move"
        var stage = "waiting"
        logEvent(.stackMutationStarted, fields: ["state": operation, "count": String(ids.count)])
        do {
            try await waitForStackWriteTurn(client: client, account: account, connection: connection)
            guard ids.allSatisfy({ isNASNotebook($0) && !deletingNotebookIDs.contains($0) }) else {
                throw NoteStationError.invalidArgument("notebookIDs")
            }
            stage = "nas"
            let remote = try await client.moveNotebooksToStack(ids: ids, name: name, creatingNew: creatingNew)
            stage = "local"
            try await installStackSnapshot(remote, client: client, account: account, connection: connection, repo: repo)
            logEvent(.stackMutationCompleted, fields: ["state": operation, "count": String(ids.count)])
        } catch {
            logEvent(.stackMutationFailed, fields: ["state": "\(operation).\(stage)", "count": String(ids.count)], error: error)
            throw error
        }
    }

    func renameStack(oldName: String, name: String) async throws {
        guard let client, canManageNASNotebooks, !isManagingStacks else {
            throw NoteStationError.writeContractUnvalidated
        }
        isManagingStacks = true
        defer { isManagingStacks = false; scheduleUpload() }
        let account = accountGeneration, connection = connectionGeneration, repo = repository
        var stage = "waiting"
        logEvent(.stackMutationStarted, fields: ["state": "rename"])
        do {
            try await waitForStackWriteTurn(client: client, account: account, connection: connection)
            stage = "nas"
            let remote = try await client.renameStack(from: oldName, to: name)
            stage = "local"
            try await installStackSnapshot(remote, client: client, account: account, connection: connection, repo: repo)
            logEvent(.stackMutationCompleted, fields: ["state": "rename"])
        } catch {
            logEvent(.stackMutationFailed, fields: ["state": "rename.\(stage)"], error: error)
            throw error
        }
    }

    func deleteStack(name: String) async throws {
        guard let client, canManageNASNotebooks, !isManagingStacks else {
            throw NoteStationError.writeContractUnvalidated
        }
        isManagingStacks = true
        defer { isManagingStacks = false; scheduleUpload() }
        let account = accountGeneration, connection = connectionGeneration, repo = repository
        try await waitForStackWriteTurn(client: client, account: account, connection: connection)
        let remote = try await client.deleteStack(name: name)
        try await installStackSnapshot(remote, client: client, account: account, connection: connection, repo: repo)
    }

    func promptRenameStack(_ oldName: String) {
        let account = accountGeneration
        let alert = NSAlert()
        alert.messageText = appText("Rename Stack")
        alert.informativeText = appText("Change the stack’s name on the NAS.")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = oldName; alert.accessoryView = input
        alert.addButton(withTitle: appText("Rename")); alert.addButton(withTitle: appText("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            guard account == accountGeneration else { return }
            do {
                try await renameStack(oldName: oldName, name: newName)
                if account == accountGeneration { stackSuccessMessage = appText("The NAS list confirms the stack name “%@”.", "\(newName)") }
            }
            catch { if account == accountGeneration { errorMessage = error.localizedDescription } }
        }
    }

    func promptDeleteStack(_ name: String) {
        let account = accountGeneration
        let alert = NSAlert()
        alert.messageText = appText("Delete the “%@” stack?", "\(name)")
        alert.informativeText = appText("This removes the stack grouping. Its notebooks and notes are kept.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: appText("Delete Stack")); alert.addButton(withTitle: appText("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            guard account == accountGeneration else { return }
            do { try await deleteStack(name: name) }
            catch { if account == accountGeneration { errorMessage = error.localizedDescription } }
        }
    }

    func promptMoveNotebook(_ notebook: Notebook, to name: String) {
        let account = accountGeneration
        Task {
            guard account == accountGeneration else { return }
            do { try await moveNotebooksToStack(ids: [notebook.id], name: name) }
            catch { if account == accountGeneration { errorMessage = error.localizedDescription } }
        }
    }
}
