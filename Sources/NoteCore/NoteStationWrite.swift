import Foundation

struct NoteStationWrite: Sendable {
    var objectID: String?
    var baseVersion: String?
    var title: String?
    var notebookID: String?
    var html: String?
    var tags: [String]?
    var recycle: Bool?
}
struct NoteStationUpload: Sendable {
    var name: String
    var mimeType: String
    var bytes: Data
    var reference: String?
}
struct NoteStationWriteReceipt: Sendable { var objectID: String; var version: String }
