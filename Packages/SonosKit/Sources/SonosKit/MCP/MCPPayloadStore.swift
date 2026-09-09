/// MCPPayloadStore.swift — Request and response payloads of MCP calls,
/// one small JSON file each under Application Support, written off the
/// main thread and read only when Diagnostics shows a row or a bug
/// bundle is built. The in-memory activity ring keeps summaries only.
/// Kept to the newest `keepLimit` files and `maxTotalBytes` overall.
import Foundation

public struct MCPPayload: Codable, Sendable {
    public let request: String?
    public let response: String?
}

public final class MCPPayloadStore: @unchecked Sendable {
    public static let shared = MCPPayloadStore()

    public static let keepLimit = 300
    public static let maxTotalBytes = 20 * 1024 * 1024
    /// Per-payload cap before writing; a 500-row queue read is truncated.
    public static let payloadCap = 64 * 1024

    private let directory: URL
    private let queue = DispatchQueue(label: "com.choragus.mcp.payloads", qos: .utility)

    init(directory: URL = AppPaths.appSupportDirectory.appendingPathComponent("mcp-payloads", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    private func url(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    /// Writes in the background; the caller never waits.
    func save(id: UUID, request: [String: Any]?, response: Any?) {
        let payload = MCPPayload(request: request.map(Self.prettyJSON), response: response.map(Self.prettyJSON))
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(payload) else { return }
            try? data.write(to: url(for: id), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(for: id).path)
            prune()
        }
    }

    public func load(id: UUID) async -> MCPPayload? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let payload = (try? Data(contentsOf: url(for: id))).flatMap { try? JSONDecoder().decode(MCPPayload.self, from: $0) }
                continuation.resume(returning: payload)
            }
        }
    }

    /// Direct read for the bug-report export, which runs on the caller's
    /// thread and is rare; at most a hundred small files.
    public func loadSync(id: UUID) -> MCPPayload? {
        (try? Data(contentsOf: url(for: id))).flatMap { try? JSONDecoder().decode(MCPPayload.self, from: $0) }
    }

    public func removeAll() {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
    }

    /// Oldest files go first, by count then by total size.
    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var rows = files.compactMap { file -> (URL, Date, Int)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        rows.sort { $0.1 > $1.1 }
        var total = 0
        for (index, row) in rows.enumerated() {
            total += row.2
            if index >= Self.keepLimit || total > Self.maxTotalBytes {
                try? FileManager.default.removeItem(at: row.0)
            }
        }
    }

    static func prettyJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return String(describing: object)
        }
        let text = String(decoding: data, as: UTF8.self)
        return text.count > payloadCap ? String(text.prefix(payloadCap)) + "\n… (truncated)" : text
    }
}
