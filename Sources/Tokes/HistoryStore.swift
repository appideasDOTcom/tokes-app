import Foundation

/// Append-only JSONL store of usage samples in Application Support.
/// The API only reports *current* utilization, so the line charts are built
/// from these locally recorded samples.
final class HistoryStore {
    private static let retention: TimeInterval = 8 * 24 * 3600

    private let fileURL: URL
    private(set) var samples: [UsageSample] = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tokes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.jsonl")
        load()
    }

    private func load() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let cutoff = Date().addingTimeInterval(-Self.retention)
        samples = text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(UsageSample.self, from: data)
        }
        .filter { $0.t >= cutoff }
        .sorted { $0.t < $1.t }
        rewrite()
    }

    func append(_ sample: UsageSample) {
        samples.append(sample)
        guard let data = try? encoder.encode(sample),
              let line = String(data: data, encoding: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try? Data((line + "\n").utf8).write(to: fileURL)
        }
    }

    /// Compacts the on-disk file to the retained window (called after load).
    private func rewrite() {
        let lines = samples.compactMap { sample -> String? in
            guard let data = try? encoder.encode(sample) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: fileURL)
    }
}
