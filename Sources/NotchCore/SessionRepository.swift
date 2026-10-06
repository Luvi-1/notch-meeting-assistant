import Foundation

public struct SessionLoadResult: Sendable {
    public var sessions: [ListeningSession]
    public var warnings: [String]
}
public actor SessionRepository {
    public let directory: URL
    private struct Envelope: Codable { let version: Int; let session: ListeningSession }
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> SessionLoadResult {
        try prepareDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        var sessions: [ListeningSession] = []
        var warnings: [String] = []
        for file in files where file.pathExtension == "json" {
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) <= 64_000_000 else { throw AssistantError("Unsupported session file.") }
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
                guard envelope.version == 1, file.deletingPathExtension().lastPathComponent == envelope.session.id.uuidString else { throw AssistantError("Unsupported session version or identity.") }
                var session = envelope.session
                if session.endedAt == nil {
                    session.endedAt = session.segments.last?.time ?? session.startedAt
                    session.recovered = true
                }
                sessions.append(session)
            } catch { warnings.append("Could not read \(file.lastPathComponent). The original file has been preserved.") }
        }
        return SessionLoadResult(sessions: sessions.sorted { $0.startedAt > $1.startedAt }, warnings: warnings)
    }
    public func save(_ session: ListeningSession) throws {
        try prepareDirectory()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, session: session))
        let file = directory.appendingPathComponent(session.id.uuidString + ".json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func delete(_ id: UUID) throws {
        let file = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
