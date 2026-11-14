import Foundation

struct DiagnosticLogPolicy: Equatable, Sendable {
    static let mebibyte = 1024 * 1024
    static let fileSizesMiB = [1, 2, 5, 10]
    static let totalSizesMiB = [1, 2, 4, 8, 16, 32, 64]
    let maximumFileBytes: Int
    let maximumFiles: Int
    let maximumTotalBytes: Int

    init(maximumFileBytes: Int = 2 * mebibyte, maximumFiles: Int = 4,
         maximumTotalBytes: Int = 8 * mebibyte) {
        self.maximumFileBytes = min(max(1, maximumFileBytes), 10 * Self.mebibyte)
        self.maximumFiles = min(max(1, maximumFiles), 20)
        self.maximumTotalBytes = min(max(1, maximumTotalBytes), 64 * Self.mebibyte)
    }

    var effectiveFileBytes: Int { min(maximumFileBytes, maximumTotalBytes) }

    static func load(from defaults: UserDefaults) -> Self {
        Self(maximumFileBytes: defaults.object(forKey: "diagnosticLogFileBytes") as? Int ?? 2 * mebibyte,
             maximumFiles: defaults.object(forKey: "diagnosticLogMaximumFiles") as? Int ?? 4,
             maximumTotalBytes: defaults.object(forKey: "diagnosticLogTotalBytes") as? Int ?? 8 * mebibyte)
    }

    func persist(to defaults: UserDefaults) {
        defaults.set(maximumFileBytes, forKey: "diagnosticLogFileBytes")
        defaults.set(maximumFiles, forKey: "diagnosticLogMaximumFiles")
        defaults.set(maximumTotalBytes, forKey: "diagnosticLogTotalBytes")
    }
}

extension DiagnosticLog {
    /// Recognize only files owned by this logger, never unrelated files.
    static func rotationIndex(for name: String) -> Int? {
        if name == "app.jsonl" { return 0 }
        guard name.hasPrefix("app."), name.hasSuffix(".jsonl") else { return nil }
        let number = String(name.dropFirst(4).dropLast(6))
        guard let index = Int(number), index > 0, String(index) == number else { return nil }
        return index
    }
}
