import Foundation

enum NoteStationMultipart {
    struct File: Sendable {
        let partName: String
        let filename: String
        let mimeType: String
        let data: Data
    }
    static func request(from original: URLRequest, files: [File]) throws -> URLRequest {
        guard let url = original.url, let bytes = original.httpBody,
              var target = URLComponents(url: url, resolvingAgainstBaseURL: false), target.query == nil else {
            throw NoteStationError.invalidArgument("multipart")
        }
        var form = URLComponents()
        form.percentEncodedQuery = String(decoding: bytes, as: UTF8.self)
        guard let fields = form.queryItems else { throw NoteStationError.invalidArgument("multipart") }
        let names: Set<String> = ["api", "method", "version", "_sid"]
        let routing = fields.filter { names.contains($0.name) }
        guard routing.count == names.count, Set(routing.map(\.name)) == names else { throw NoteStationError.invalidArgument("multipart") }
        // Synology dispatches multipart by query parameters before reading the
        // body. The official client also puts api/method/version/_sid here.
        target.queryItems = routing
        form.queryItems = fields.filter { !names.contains($0.name) }
        let boundary = "SynologyNote-\(UUID().uuidString)"
        var request = original
        request.url = target.url
        request.httpBody = try encode(urlEncodedFields: Data((form.percentEncodedQuery ?? "").utf8), files: files, boundary: boundary)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }
    static func encode(urlEncodedFields: Data, files: [File], boundary: String) throws -> Data {
        func safe(_ value: String) -> Bool {
            !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 && $0.value != 34 && $0.value != 92 }
        }
        guard safe(boundary), !files.isEmpty, files.allSatisfy({ safe($0.partName) && safe($0.filename) && safe($0.mimeType) }),
              Set(files.map(\.partName)).count == files.count else { throw NoteStationError.invalidArgument("multipart") }
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: urlEncodedFields, as: UTF8.self)
        guard let fields = components.queryItems, fields.allSatisfy({ safe($0.name) && $0.value != nil }),
              !files.contains(where: { file in fields.contains(where: { $0.name == file.partName }) }) else {
            throw NoteStationError.invalidArgument("multipart")
        }
        var data = Data()
        func append(_ value: String) { data.append(contentsOf: value.utf8) }
        for field in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n\(field.value!)\r\n")
        }
        for file in files {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.partName)\"; filename=\"\(file.filename)\"\r\nContent-Type: \(file.mimeType)\r\n\r\n")
            data.append(file.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return data
    }
}
